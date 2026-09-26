"""Data access for the storefront: RDS MySQL (writer and reader) and Redis.

Read path : Redis -> read replica -> primary   (each step is a fallback)
Write path: primary only, then invalidate the cached catalog
"""

import json
import logging
import os
import threading
import time

import boto3
import pymysql
import redis
from botocore.exceptions import BotoCoreError, ClientError
from pymysql.cursors import DictCursor

log = logging.getLogger("storefront.data")

CONFIG_PATH = os.environ.get("STOREFRONT_CONFIG", "/etc/storefront/config.json")
CATALOG_KEY = "catalog:v1"

# Errors that mean "this dependency is unavailable right now". Secrets Manager
# errors are included because every connection starts with a credential lookup.
DB_ERRORS = (pymysql.MySQLError, BotoCoreError, ClientError)
CACHE_ERRORS = (redis.RedisError, BotoCoreError, ClientError)


def load_config():
    with open(CONFIG_PATH, encoding="utf-8") as fh:
        return json.load(fh)


CONFIG = load_config()
_secrets = boto3.client("secretsmanager", region_name=CONFIG["region"])


# -----------------------------------------------------------------------------
# Secrets, cached in memory and refreshed on demand (the RDS secret rotates)
# -----------------------------------------------------------------------------
class SecretCache:
    def __init__(self, max_age_seconds=300):
        self._max_age = max_age_seconds
        self._values = {}
        self._lock = threading.Lock()

    def get(self, arn, force=False):
        with self._lock:
            cached = self._values.get(arn)
            if cached and not force and time.time() - cached[1] < self._max_age:
                return cached[0]
            value = _secrets.get_secret_value(SecretId=arn)["SecretString"]
            self._values[arn] = (value, time.time())
            return value


SECRETS = SecretCache()


def _db_credentials(force=False):
    secret = json.loads(SECRETS.get(CONFIG["db_secret_arn"], force=force))
    return secret["username"], secret["password"]


# -----------------------------------------------------------------------------
# MySQL
# -----------------------------------------------------------------------------
class DatabaseUnavailable(Exception):
    """Raised when neither the replica nor the primary can serve a request."""


class OutOfStock(Exception):
    pass


class UnknownProduct(Exception):
    pass


def connect(role):
    """Open a TLS connection to the writer or reader endpoint.

    If authentication fails the secret may have just rotated, so the
    credentials are refetched once before giving up.
    """
    host = CONFIG["db_writer_host"] if role == "writer" else CONFIG["db_reader_host"]
    for attempt in (1, 2):
        user, password = _db_credentials(force=attempt == 2)
        try:
            return pymysql.connect(
                host=host,
                user=user,
                password=password,
                database=CONFIG["db_name"],
                ssl={"ca": CONFIG["db_ca_path"]},
                connect_timeout=3,
                read_timeout=5,
                write_timeout=5,
                autocommit=False,
                cursorclass=DictCursor,
                charset="utf8mb4",
            )
        except pymysql.err.OperationalError as exc:
            access_denied = exc.args and exc.args[0] == 1045
            if access_denied and attempt == 1:
                log.warning("access denied on %s, refreshing credentials", role)
                continue
            raise
    raise DatabaseUnavailable(role)


SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS products (
        id          INT PRIMARY KEY,
        sku         VARCHAR(32)  NOT NULL UNIQUE,
        name        VARCHAR(120) NOT NULL,
        description VARCHAR(255) NOT NULL,
        price_cents INT          NOT NULL,
        stock       INT          NOT NULL,
        updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB
    """,
    """
    CREATE TABLE IF NOT EXISTS orders (
        id          BIGINT AUTO_INCREMENT PRIMARY KEY,
        product_id  INT         NOT NULL,
        quantity    INT         NOT NULL,
        total_cents INT         NOT NULL,
        served_by   VARCHAR(32) NOT NULL,
        az          VARCHAR(32) NOT NULL,
        created_at  TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT fk_orders_product FOREIGN KEY (product_id) REFERENCES products (id),
        INDEX idx_orders_created (created_at)
    ) ENGINE=InnoDB
    """,
]

SEED_PRODUCTS = [
    (1, "SKU-1001", "Wireless Earbuds", "Noise cancelling, 24 hour battery", 7999, 50000),
    (2, "SKU-1002", "Smart Watch", "Heart rate, GPS, sleep tracking", 19999, 50000),
    (3, "SKU-1003", "USB-C Charger 65W", "Fast charging for laptop and phone", 3999, 50000),
    (4, "SKU-1004", "Mechanical Keyboard", "Hot swappable switches, backlit", 8999, 50000),
    (5, "SKU-1005", "4K Webcam", "Auto focus with dual microphones", 12999, 50000),
    (6, "SKU-1006", "Portable SSD 1TB", "USB 3.2, up to 1050 MB/s", 10999, 50000),
    (7, "SKU-1007", "Laptop Stand", "Aluminium, adjustable height", 4499, 50000),
    (8, "SKU-1008", "Bluetooth Speaker", "Waterproof, 12 hour playtime", 5999, 50000),
]


def init_db():
    """Create tables and seed products. Safe to run on every instance at boot."""
    conn = connect("writer")
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT GET_LOCK('storefront_init', 30) AS got")
            if not cur.fetchone()["got"]:
                raise RuntimeError("could not obtain the init lock")
            for statement in SCHEMA:
                cur.execute(statement)
            cur.executemany(
                "INSERT IGNORE INTO products (id, sku, name, description, price_cents, stock) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                SEED_PRODUCTS,
            )
            conn.commit()
            cur.execute("SELECT RELEASE_LOCK('storefront_init')")
    finally:
        conn.close()


# -----------------------------------------------------------------------------
# Redis
# -----------------------------------------------------------------------------
_redis = None
_redis_lock = threading.Lock()


def cache():
    global _redis
    with _redis_lock:
        if _redis is None:
            _redis = redis.Redis(
                host=CONFIG["redis_host"],
                port=6379,
                password=SECRETS.get(CONFIG["redis_secret_arn"]),
                ssl=True,
                socket_timeout=0.5,
                socket_connect_timeout=0.5,
                decode_responses=True,
                health_check_interval=30,
            )
        return _redis


# -----------------------------------------------------------------------------
# Use cases
# -----------------------------------------------------------------------------
def get_catalog():
    """Return (source, products). source is cache, replica or primary."""
    try:
        cached = cache().get(CATALOG_KEY)
        if cached:
            return "cache", json.loads(cached)
    except CACHE_ERRORS as exc:
        log.warning("cache read failed: %s", exc)

    products, source = None, None
    for role, label in (("reader", "replica"), ("writer", "primary")):
        try:
            conn = connect(role)
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id, sku, name, description, price_cents, stock "
                        "FROM products ORDER BY id"
                    )
                    products, source = cur.fetchall(), label
                break
            finally:
                conn.close()
        except DB_ERRORS as exc:
            log.warning("catalog read from %s failed: %s", label, exc)

    if products is None:
        raise DatabaseUnavailable("catalog")

    try:
        cache().setex(CATALOG_KEY, CONFIG.get("cache_ttl_seconds", 60), json.dumps(products))
    except CACHE_ERRORS as exc:
        log.warning("cache write failed: %s", exc)

    return source, products


def place_order(product_id, quantity, served_by, az):
    """Decrement stock and record the order in one transaction on the primary."""
    try:
        conn = connect("writer")
    except DB_ERRORS as exc:
        raise DatabaseUnavailable("writer") from exc
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT price_cents, stock FROM products WHERE id = %s FOR UPDATE",
                (product_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise UnknownProduct(product_id)
            if row["stock"] < quantity:
                raise OutOfStock(product_id)
            total = row["price_cents"] * quantity
            cur.execute(
                "UPDATE products SET stock = stock - %s WHERE id = %s",
                (quantity, product_id),
            )
            cur.execute(
                "INSERT INTO orders (product_id, quantity, total_cents, served_by, az) "
                "VALUES (%s, %s, %s, %s, %s)",
                (product_id, quantity, total, served_by, az),
            )
            order_id = cur.lastrowid
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    try:
        cache().delete(CATALOG_KEY)
    except CACHE_ERRORS as exc:
        log.warning("cache invalidation failed: %s", exc)

    return order_id, total


def recent_orders(limit=10):
    """Read from the primary so a new order shows up immediately."""
    conn = connect("writer")
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT o.id, p.name, o.quantity, o.total_cents, o.served_by, o.az, "
                "DATE_FORMAT(o.created_at, '%%Y-%%m-%%d %%H:%%i:%%s') AS created_at "
                "FROM orders o JOIN products p ON p.id = o.product_id "
                "ORDER BY o.id DESC LIMIT %s",
                (limit,),
            )
            return cur.fetchall()
    finally:
        conn.close()


def dependency_status():
    """Probe each dependency and report latency, for /health/deep."""
    results = {}
    for role, label in (("writer", "db_primary"), ("reader", "db_replica")):
        started = time.perf_counter()
        try:
            conn = connect(role)
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
            finally:
                conn.close()
            results[label] = {"ok": True, "ms": round((time.perf_counter() - started) * 1000, 1)}
        except Exception as exc:  # noqa: BLE001 - report any failure
            results[label] = {"ok": False, "error": str(exc)[:200]}

    started = time.perf_counter()
    try:
        cache().ping()
        results["cache"] = {"ok": True, "ms": round((time.perf_counter() - started) * 1000, 1)}
    except Exception as exc:  # noqa: BLE001
        results["cache"] = {"ok": False, "error": str(exc)[:200]}
    return results
