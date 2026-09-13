"""Check the distributable manifest and its actual payload, not a fixture bundle."""
import json
from pathlib import Path
import unittest


class BundleContractTests(unittest.TestCase):
    def test_manifest_lists_every_payload_once(self):
        bundle = Path(__file__).parents[1] / 'bundle'
        manifest = json.loads((bundle / 'manifest.json').read_text())
        self.assertEqual(manifest['schema'], 1)
        paths = manifest['files']
        self.assertEqual(len(paths), len(set(paths)))
        actual = {p.relative_to(bundle).as_posix() for p in bundle.rglob('*')
                  if p.is_file() and '__pycache__' not in p.parts and p.name != 'manifest.json'}
        self.assertEqual(set(paths), actual)
        for name in paths:
            data = (bundle / name).read_text()
            self.assertNotIn('/Users/', data, name)
            self.assertNotIn('/home/', data, name)
            self.assertNotIn('chatled', data.lower(), name)

    def test_adapters_require_the_same_workflow(self):
        root = Path(__file__).parents[1] / 'bundle'
        for name in ('claude', 'codex'):
            self.assertIn('.workflow/vendor/WORKFLOW.md', (root / 'adapters' / f'{name}.md').read_text())
