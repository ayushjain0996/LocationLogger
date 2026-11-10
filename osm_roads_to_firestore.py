"""Download Dublin's drivable road network from OpenStreetMap (Overpass API)
and store it in Cloud Firestore next to your location data.

Usage:
    pip install firebase-admin requests
    python osm_roads_to_firestore.py service-account.json            # download + upload
    python osm_roads_to_firestore.py service-account.json --dry-run  # download only

What it writes:
    osm_meta/dublin_roads          when and how the data was fetched (+ OSM licence)
    osm_tiles/{tile_id}            roads grouped into ~1 km grid tiles, each road with
                                   id, name, highway, maxspeed_kmh, maxspeed_raw,
                                   oneway and its geometry as a list of points

Roads are grouped into tiles (instead of one document per road) so the upload
is a few hundred writes, well inside Firebase's free daily limit, and so the
analysis can fetch just the tiles around a trip. A copy is also saved locally
as dublin_roads.geojson.

OpenStreetMap data is (c) OpenStreetMap contributors, available under the
Open Database Licence (ODbL). Credit it in your report.
"""
import datetime as dt
import json
import math
import re
import sys
from collections import defaultdict

import requests

OVERPASS_URL = "https://overpass-api.de/api/interpreter"

# South, west, north, east. Covers Dublin city and the surrounding suburbs.
BBOX = (53.25, -6.45, 53.45, -6.05)

# Roads cars use. Service roads, tracks and footpaths are left out.
HIGHWAY_TYPES = [
    "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    "secondary", "secondary_link", "tertiary", "tertiary_link",
    "unclassified", "residential", "living_street",
]

TILE_DEG = 0.01  # about 1.1 km north-south, 0.66 km east-west at Dublin's latitude


def build_query(bbox=BBOX):
    s, w, n, e = bbox
    types = "|".join(HIGHWAY_TYPES)
    return (
        "[out:json][timeout:300];\n"
        f'way["highway"~"^({types})$"]({s},{w},{n},{e});\n'
        "out tags geom;"
    )


def parse_maxspeed(raw):
    """'50' -> 50, '30 mph' -> 48, anything else (e.g. 'IE:urban', 'signals') -> None."""
    if not raw:
        return None
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(mph|km/h|kmh)?\s*", raw)
    if not m:
        return None
    value = float(m.group(1))
    if m.group(2) == "mph":
        value *= 1.609344
    return round(value)


def parse_oneway(tags):
    """True / False, or 'reverse' when the way is one-way against its drawing direction."""
    value = tags.get("oneway")
    if value in ("yes", "true", "1"):
        return True
    if value == "-1":
        return "reverse"
    if value in ("no", "false", "0"):
        return False
    # Motorways and roundabouts are one-way by default in OSM.
    return tags.get("highway") in ("motorway", "motorway_link") or tags.get("junction") == "roundabout"


def tile_id(lat, lon):
    return f"{math.floor(lat / TILE_DEG)}_{math.floor(lon / TILE_DEG)}"


def to_roads(overpass_json):
    roads = []
    for el in overpass_json.get("elements", []):
        if el.get("type") != "way" or not el.get("geometry"):
            continue
        tags = el.get("tags", {})
        points = [(p["lat"], p["lon"]) for p in el["geometry"]]
        roads.append({
            "id": el["id"],
            "name": tags.get("name"),
            "highway": tags.get("highway"),
            "maxspeed_raw": tags.get("maxspeed"),
            "maxspeed_kmh": parse_maxspeed(tags.get("maxspeed")),
            "oneway": parse_oneway(tags),
            "points": points,
        })
    return roads


def group_into_tiles(roads):
    """Each road goes in the tile of its middle point."""
    tiles = defaultdict(list)
    for road in roads:
        lat, lon = road["points"][len(road["points"]) // 2]
        tiles[tile_id(lat, lon)].append(road)
    return tiles


def to_geojson(roads):
    return {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "id": r["id"],
                "properties": {k: v for k, v in r.items() if k != "points"},
                "geometry": {"type": "LineString",
                             "coordinates": [[lon, lat] for lat, lon in r["points"]]},
            }
            for r in roads
        ],
    }


def upload(roads, tiles, key_path, query, fetched_at):
    import firebase_admin
    from firebase_admin import credentials, firestore

    firebase_admin.initialize_app(credentials.Certificate(key_path))
    db = firestore.client()

    batch, pending = db.batch(), 0
    for tid, tile_roads in tiles.items():
        doc = {
            "tile_deg": TILE_DEG,
            "count": len(tile_roads),
            "roads": [
                {**{k: v for k, v in r.items() if k != "points"},
                 # Firestore can't nest arrays directly, so each point is a GeoPoint.
                 "points": [firestore.GeoPoint(lat, lon) for lat, lon in r["points"]]}
                for r in tile_roads
            ],
        }
        batch.set(db.collection("osm_tiles").document(tid), doc)
        pending += 1
        if pending == 400:  # Firestore allows at most 500 writes per batch
            batch.commit()
            batch, pending = db.batch(), 0
    if pending:
        batch.commit()

    with_limit = sum(1 for r in roads if r["maxspeed_kmh"] is not None)
    db.collection("osm_meta").document("dublin_roads").set({
        "source": "OpenStreetMap via Overpass API",
        "licence": "ODbL, (c) OpenStreetMap contributors",
        "query": query,
        "bbox_swne": list(BBOX),
        "fetched_at": fetched_at,
        "road_count": len(roads),
        "roads_with_maxspeed": with_limit,
        "tile_count": len(tiles),
    })


def main():
    key_path = sys.argv[1]
    dry_run = "--dry-run" in sys.argv

    query = build_query()
    print("Querying Overpass (this can take a minute)...")
    response = requests.post(OVERPASS_URL, data={"data": query}, timeout=360,
                             headers={"User-Agent": "LocationLogger-student-project"})
    response.raise_for_status()
    fetched_at = dt.datetime.now(dt.timezone.utc)

    roads = to_roads(response.json())
    tiles = group_into_tiles(roads)
    with_limit = sum(1 for r in roads if r["maxspeed_kmh"] is not None)
    print(f"{len(roads)} roads, {with_limit} with a numeric maxspeed, {len(tiles)} tiles")

    with open("dublin_roads.geojson", "w") as f:
        json.dump(to_geojson(roads), f)
    print("Saved dublin_roads.geojson")

    if dry_run:
        print("Dry run: nothing uploaded.")
        return
    upload(roads, tiles, key_path, query, fetched_at)
    print(f"Uploaded {len(tiles)} tiles to osm_tiles and metadata to osm_meta/dublin_roads.")


if __name__ == "__main__":
    main()
