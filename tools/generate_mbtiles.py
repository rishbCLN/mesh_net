#!/usr/bin/env python3
"""
Download OSM tiles for VIT Vellore campus area and pack into an MBTiles file.

MBTiles spec: https://github.com/mapbox/mbtiles-spec
This creates a SQLite database with tiles table that the app's
MBTilesTileProvider can read directly.

Coverage: ~3km radius around VIT Vellore (12.9692, 79.1559)
Zoom levels: 14-17 (street-level detail)
"""

import sqlite3
import os
import sys
import math
import time
import urllib.request

# ── Configuration ──────────────────────────────────────────────────────────
CENTER_LAT = 12.9692
CENTER_LNG = 79.1559
RADIUS_KM = 3.0
MIN_ZOOM = 14
MAX_ZOOM = 17
OUTPUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      'assets', 'maps', 'region.mbtiles')

USER_AGENT = 'MeshAlert disaster-response/1.0 (offline-map-builder)'

# ── Tile math ──────────────────────────────────────────────────────────────
def lng_to_tile_x(lng, z):
    return int((lng + 180.0) / 360.0 * (1 << z))

def lat_to_tile_y(lat, z):
    lat_rad = math.radians(lat)
    return int((1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * (1 << z))

def xyz_to_tms_y(y, z):
    """Convert XYZ y to TMS y (MBTiles uses TMS)."""
    return (1 << z) - 1 - y

def main():
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)

    # Remove old file if exists
    if os.path.exists(OUTPUT):
        os.remove(OUTPUT)

    # Approximate degrees per km at this latitude
    lat_delta = RADIUS_KM / 111.0
    lng_delta = RADIUS_KM / (111.0 * math.cos(math.radians(CENTER_LAT)))

    # Count total tiles
    total = 0
    tile_list = []
    for z in range(MIN_ZOOM, MAX_ZOOM + 1):
        x_min = lng_to_tile_x(CENTER_LNG - lng_delta, z)
        x_max = lng_to_tile_x(CENTER_LNG + lng_delta, z)
        y_min = lat_to_tile_y(CENTER_LAT + lat_delta, z)  # y increases downward
        y_max = lat_to_tile_y(CENTER_LAT - lat_delta, z)
        for x in range(x_min, x_max + 1):
            for y in range(y_min, y_max + 1):
                tile_list.append((z, x, y))
        total += (x_max - x_min + 1) * (y_max - y_min + 1)

    print(f"Will download {total} tiles for zoom {MIN_ZOOM}-{MAX_ZOOM}")
    print(f"Area: {RADIUS_KM}km around ({CENTER_LAT}, {CENTER_LNG})")
    print(f"Output: {OUTPUT}")
    print()

    # Create MBTiles database
    conn = sqlite3.connect(OUTPUT)
    cur = conn.cursor()

    # MBTiles schema
    cur.execute('''CREATE TABLE metadata (name TEXT, value TEXT)''')
    cur.execute('''CREATE TABLE tiles (
        zoom_level INTEGER,
        tile_column INTEGER,
        tile_row INTEGER,
        tile_data BLOB
    )''')
    cur.execute('''CREATE UNIQUE INDEX idx_tiles ON tiles (zoom_level, tile_column, tile_row)''')

    # Metadata
    metadata = [
        ('name', 'MeshAlert VIT Vellore'),
        ('type', 'baselayer'),
        ('version', '1'),
        ('description', 'Offline OSM tiles for VIT Vellore campus area'),
        ('format', 'png'),
        ('bounds', f'{CENTER_LNG - lng_delta},{CENTER_LAT - lat_delta},{CENTER_LNG + lng_delta},{CENTER_LAT + lat_delta}'),
        ('center', f'{CENTER_LNG},{CENTER_LAT},{MIN_ZOOM}'),
        ('minzoom', str(MIN_ZOOM)),
        ('maxzoom', str(MAX_ZOOM)),
    ]
    cur.executemany('INSERT INTO metadata VALUES (?, ?)', metadata)

    # Download tiles
    downloaded = 0
    failed = 0
    for i, (z, x, y) in enumerate(tile_list):
        url = f'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
        tms_y = xyz_to_tms_y(y, z)

        try:
            req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()

            cur.execute('INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?)',
                        (z, x, tms_y, data))
            downloaded += 1
        except Exception as e:
            failed += 1
            print(f"  FAIL {z}/{x}/{y}: {e}")

        # Progress
        if (i + 1) % 10 == 0 or i + 1 == len(tile_list):
            pct = (i + 1) / len(tile_list) * 100
            print(f"  [{pct:5.1f}%] {i+1}/{len(tile_list)} tiles (ok={downloaded}, fail={failed})", end='\r')

        # Rate limit: OSM tile usage policy (max ~2 req/sec for bulk)
        time.sleep(0.5)

    conn.commit()

    # Report
    file_size_mb = os.path.getsize(OUTPUT) / (1024 * 1024)
    print(f"\n\nDone!")
    print(f"  Downloaded: {downloaded}")
    print(f"  Failed:     {failed}")
    print(f"  File size:  {file_size_mb:.1f} MB")
    print(f"  Output:     {OUTPUT}")

    conn.close()

if __name__ == '__main__':
    main()
