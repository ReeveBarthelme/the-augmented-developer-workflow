#!/usr/bin/env python3
"""Compatibility entrypoint for the canonical bundled workflow synchronizer."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bundle.sync import main


if __name__ == "__main__":
    main()
