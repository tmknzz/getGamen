import concurrent.futures
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('stamp_build', Path(__file__).with_name('stamp-build.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildNumberTests(unittest.TestCase):
    def test_sequence_and_rollover(self):
        self.assertEqual(module.next_number(None, '20261004'), ('20261004AA', 1))
        self.assertEqual(module.next_number('20261004AA', '20261004'), ('20261004AB', 2))
        self.assertEqual(module.next_number('20261004AB', '20261004'), ('20261004AC', 3))
        self.assertEqual(module.next_number('20261004AZ', '20261004'), ('20261004BA', 27))
        self.assertEqual(module.next_number('20261004ZZ', '20261005'), ('20261005AA', 1))

    def test_invalid_or_exhausted_numbers_do_not_wrap(self):
        for previous, day in [('bad', '20261004'), ('20261005AA', '20261004'), ('20261004ZZ', '20261004')]:
            with self.assertRaises(ValueError):
                module.next_number(previous, day)

    def test_concurrent_builds_have_unique_matching_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Info.plist'
            source.write_bytes(plistlib.dumps({'CFBundleVersion': '2'}))
            def build(index):
                output = root / f'{index}.plist'
                result = subprocess.run([sys.executable, str(Path(module.__file__)), str(source), str(output)], check=True, capture_output=True, text=True)
                info = plistlib.loads(output.read_bytes())
                self.assertEqual(result.stdout.strip(), info['getGamenBuildNumber'])
                return info
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                infos = list(executor.map(build, range(8)))
            self.assertEqual(sorted(i['getGamenBuildNumber'][-2:] for i in infos), ['AA', 'AB', 'AC', 'AD', 'AE', 'AF', 'AG', 'AH'])
            self.assertEqual({i['CFBundleVersion'].split('.')[1] for i in infos}, set(map(str, range(1, 9))))
            self.assertEqual(plistlib.loads(source.read_bytes())['getGamenBuildNumber'][-2:], 'AH')


if __name__ == '__main__':
    unittest.main()
