#!/usr/bin/env python3
"""Read images.yaml and write env vars to /tmp/image-config.env"""
import yaml, os

os_name = os.environ['OS']
config = yaml.safe_load(open('image-builder/images.yaml'))['images'][os_name]

with open('/tmp/image-config.env', 'w') as f:
    f.write(f"IMAGE_URL={config['image_url']}\n")
    f.write(f"IMAGE_CHECKSUM={config['image_checksum']}\n")
