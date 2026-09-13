import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class DoctorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('doctor', Path(__file__).parents[1] / 'bundle/doctor.py')
        cls.doctor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.doctor)

    def test_missing_required_tool_fails_optional_does_not(self):
        config = {'schema': 1, 'required_tools': ['git'], 'optional_tools': ['claude'], 'required_files': []}
        with tempfile.TemporaryDirectory() as folder, patch.object(self.doctor.shutil, 'which', return_value=None):
            results = self.doctor.inspect(Path(folder), config)
        self.assertEqual([(r['name'], r['status'], r['required']) for r in results],
                         [('git', 'missing', True), ('claude', 'missing', False)])

    def test_present_tool_is_not_authenticated(self):
        config = {'schema': 1, 'required_tools': ['gh'], 'required_files': ['README.md']}
        with tempfile.TemporaryDirectory() as folder, patch.object(self.doctor.shutil, 'which', return_value='/bin/gh'):
            Path(folder, 'README.md').write_text('hello')
            results = self.doctor.inspect(Path(folder), config)
        self.assertEqual([r['status'] for r in results], ['available', 'present'])
        self.assertEqual(results[0]['authentication'], 'not checked')

    def test_rejects_unsafe_configuration(self):
        for config in ({'schema': 2}, {'schema': 1, 'required_files': ['../secret']},
                       {'schema': 1, 'required_tools': ['sh -c evil']},
                       {'schema': 1, 'required_tools': 'git'}):
            with self.subTest(config=config), self.assertRaises(ValueError):
                self.doctor.validate(config)
