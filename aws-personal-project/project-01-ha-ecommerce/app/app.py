"""Storefront web application (Flask), served by gunicorn behind nginx.

Every response carries the instance ID and Availability Zone that produced it,
so load balancing, scaling and failover are visible from the browser and from
the test scripts.
"""

import hashlib
import logging
import os
import time
import urllib.request

from flask import Flask, jsonify, render_template, request

import data

# -----------------------------------------------------------------------------
# Logging to /var/log/storefront/app.log (shipped by the CloudWatch agent)
# -----------------------------------------------------------------------------
LOG_DIR = "/var/log/storefront"
handlers = [logging.StreamHandler()]
if os.path.isdir(LOG_DIR) and os.access(LOG_DIR, os.W_OK):
    handlers.append(logging.FileHandler(os.path.join(LOG_DIR, "app.log")))
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    handlers=handlers,
)
log = logging.getLogger("storefront")


# -----------------------------------------------------------------------------
# Instance identity from IMDSv2
# -----------------------------------------------------------------------------
def _imds(path):
    try:
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"},
        )
        token = urllib.request.urlopen(token_req, timeout=1).read().decode()
        req = urllib.request.Request(
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
        )
        return urllib.request.urlopen(req, timeout=1).read().decode()
    except Exception:  # noqa: BLE001 - running outside EC2
        return "local"


INSTANCE_ID = _imds("instance-id")
AVAILABILITY_ZONE = _imds("placement/availability-zone")
APP_VERSION = data.CONFIG.get("app_version", "dev")[:8]

app = Flask(__name__)


@app.after_request
def identify(response):
    response.headers["X-Served-By"] = INSTANCE_ID
    response.headers["X-Served-AZ"] = AVAILABILITY_ZONE
    response.headers["X-App-Version"] = APP_VERSION
    return response


def identity():
    return {"instance": INSTANCE_ID, "az": AVAILABILITY_ZONE, "version": APP_VERSION}


# -----------------------------------------------------------------------------
# Health
# -----------------------------------------------------------------------------
@app.get("/health")
def health():
    """Shallow check used by the ALB.

    It deliberately does not touch the database or cache. If it did, a
    database failover would mark every instance unhealthy at once and the ASG
    would replace a perfectly good web tier.
    """
    return jsonify(status="ok", **identity())


@app.get("/health/deep")
def health_deep():
    deps = data.dependency_status()
    healthy = all(d["ok"] for d in deps.values())
    return jsonify(status="ok" if healthy else "degraded", dependencies=deps, **identity()), (
        200 if healthy else 503
    )


# -----------------------------------------------------------------------------
# Pages and API
# -----------------------------------------------------------------------------
@app.get("/")
def index():
    started = time.perf_counter()
    error = None
    source, products = "unavailable", []
    try:
        source, products = data.get_catalog()
    except data.DatabaseUnavailable:
        error = "The catalog is temporarily unavailable. Please try again in a moment."
    elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
    return render_template(
        "index.html",
        products=products,
        source=source,
        elapsed_ms=elapsed_ms,
        error=error,
        **identity(),
    ), (200 if error is None else 503)


@app.get("/api/info")
def info():
    return jsonify(**identity())


@app.get("/api/products")   # cached for 30 seconds at the CloudFront edge
@app.get("/api/catalog")    # same data, never cached by CloudFront (used by tests)
def products():
    try:
        source, items = data.get_catalog()
    except data.DatabaseUnavailable:
        return jsonify(error="catalog unavailable", **identity()), 503
    return jsonify(source=source, count=len(items), products=items, **identity())


@app.get("/api/orders")
def list_orders():
    try:
        return jsonify(orders=data.recent_orders(), **identity())
    except Exception as exc:  # noqa: BLE001
        log.warning("recent orders failed: %s", exc)
        return jsonify(error="orders unavailable", **identity()), 503


@app.post("/api/orders")
def create_order():
    body = request.get_json(silent=True) or {}
    try:
        product_id = int(body.get("product_id", 0))
        quantity = int(body.get("quantity", 1))
    except (TypeError, ValueError):
        return jsonify(error="product_id and quantity must be integers"), 400
    if product_id <= 0 or not 1 <= quantity <= 10:
        return jsonify(error="product_id must be positive and quantity between 1 and 10"), 400

    try:
        order_id, total = data.place_order(product_id, quantity, INSTANCE_ID, AVAILABILITY_ZONE)
    except data.UnknownProduct:
        return jsonify(error="unknown product"), 404
    except data.OutOfStock:
        return jsonify(error="out of stock"), 409
    except (data.DatabaseUnavailable, *data.DB_ERRORS) as exc:
        # Expected for a short window during a Multi-AZ failover.
        log.warning("order write failed: %s", exc)
        return jsonify(error="orders are temporarily unavailable, please retry", **identity()), 503

    log.info("order %s placed: product=%s qty=%s total=%s", order_id, product_id, quantity, total)
    return jsonify(order_id=order_id, total_cents=total, **identity()), 201


@app.get("/api/load")
def load():
    """Burn CPU for up to 2 seconds so load tests can trigger scale out."""
    try:
        ms = max(0, min(int(request.args.get("ms", 200)), 2000))
    except ValueError:
        ms = 200
    deadline = time.perf_counter() + ms / 1000
    rounds = 0
    digest = b"storefront"
    while time.perf_counter() < deadline:
        digest = hashlib.sha256(digest).digest()
        rounds += 1
    return jsonify(burned_ms=ms, rounds=rounds, **identity())
