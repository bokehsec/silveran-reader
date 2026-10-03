import copy
import importlib.machinery
import importlib.util
import json
import pathlib
import tempfile
import unittest
import zipfile

loader = importlib.machinery.SourceFileLoader('performance', str(pathlib.Path(__file__).parents[1] / 'compare-performance'))
spec = importlib.util.spec_from_loader(loader.name, loader)
tool = importlib.util.module_from_spec(spec); loader.exec_module(tool)


def report(build='100', identity='fixture', samples=100, bucket=2):
    return {'schema': 1, 'instrumentation': 1, 'id': '00000000-0000-0000-0000-000000000001',
            'identity': identity, 'source': 'activity', 'begin': '2026-10-03T10:00:00Z',
            'end': '2026-10-03T11:00:00Z', 'received': '2026-10-03T11:01:00Z',
            'environment': {'platform': 'iOS', 'deviceModel': 'iPad16,1', 'osVersion': '18.6',
                            'appVersion': '1', 'build': build, 'provenance': 'development'},
            'mixedBuilds': False, 'partial': True, 'metrics': {}, 'intervalResources': [], 'dropped': {},
            'operations': [{'operation': 'annotation.commitInk', 'coverage': 'native', 'count': samples,
                            'outcomes': {'success': samples}, 'histogram': {'buckets': [samples if n == bucket else 0 for n in range(11)]},
                            'work': {'items': samples}, 'durationSamples': samples, 'resourceSampleEvery': 16}]}


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = pathlib.Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def bundle(self, name, rows, extra=None):
        path = self.root / (name + '.zip')
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('manifest.json', json.dumps({'schema': 1, 'instrumentation': 1, 'reportCount': len(rows), 'histogramUpperBoundsSeconds': tool.BOUNDS}))
            archive.writestr('metrics.json', json.dumps({'schema': 1, 'reports': rows, 'dropped': {}, 'evicted': 0}))
            archive.writestr('summary.txt', 'synthetic fixture')
            if extra: archive.writestr(extra, 'untrusted')
        return path
    def test_seeded_regression_and_increased_usage(self):
        baseline = self.bundle('base', [report()])
        regression = self.bundle('slow', [report('101', 'slow', bucket=5)])
        usage = self.bundle('usage', [report('102', 'usage', samples=200)])
        result = tool.compare([baseline, regression, usage])
        self.assertEqual(len(result['cohorts']), 3)
        self.assertEqual(result['changes'][0]['p95UpperSecondsBefore'], .01)
        self.assertEqual(result['changes'][0]['p95UpperSecondsAfter'], .5)
        increased = next(c for c in result['changes'] if c['fromBuild'] == '100' and c['toBuild'] == '102')
        self.assertEqual(increased['p95UpperSecondsBefore'], increased['p95UpperSecondsAfter'])
        self.assertEqual(increased['countChange'], 100)
    def test_duplicates_overlap_mixed_and_models(self):
        row = report(); duplicate = copy.deepcopy(row)
        overlap = report(identity='overlap'); mixed = report('101', 'mixed'); mixed['mixedBuilds'] = True
        other = report('101', 'other'); other['environment']['deviceModel'] = 'iPhone13,4'
        result = tool.compare([self.bundle('all', [row, duplicate, overlap, mixed, other])])
        self.assertEqual(len(result['cohorts']), 2); self.assertFalse(result['changes'])
        self.assertTrue(any('duplicate' in w for w in result['warnings']))
        self.assertTrue(any('overlapping' in w for w in result['warnings']))
        self.assertTrue(any('mixed' in w for w in result['warnings']))
    def test_merge_histograms_not_percentiles(self):
        a = report(samples=90, bucket=1); b = report(identity='next', samples=10, bucket=9)
        b['begin'] = '2026-10-03T11:00:00Z'; b['end'] = '2026-10-03T12:00:00Z'
        result = tool.compare([self.bundle('histograms', [a, b])])
        op = result['cohorts'][0]['operations']['annotation.commitInk/native']
        self.assertEqual(op['p50UpperSeconds'], .005); self.assertEqual(op['p95UpperSeconds'], 60)
    def test_insufficient_missing_and_zero(self):
        row = report(samples=2); row['source'] = 'metrickit'; row['partial'] = False
        row['metrics'] = {'cpuSeconds': {'unit': 'seconds', 'value': 0, 'availability': 'available'},
                          'foregroundSeconds': {'unit': 'seconds', 'value': None, 'availability': 'missing'}}
        result = tool.compare([self.bundle('missing', [row])]); cohort = result['cohorts'][0]
        self.assertEqual(cohort['perReportMeasurements']['cpuSeconds'], [0])
        self.assertEqual(cohort['appTotalCPUSecondsPerForegroundHour'], [])
        self.assertEqual(cohort['operations']['annotation.commitInk/native']['evidence'], 'insufficient samples')
    def test_os_totals_and_matching_foreground_denominator(self):
        old = report('98', 'cpu-old'); new = report('99', 'cpu-new')
        for row, cpu, foreground in [(old, 10, 600), (new, 20, 1200)]:
            row['source'] = 'metrickit'; row['partial'] = False; row['operations'] = []
            row['metrics'] = {'cpuSeconds': {'unit': 'seconds', 'value': cpu, 'availability': 'available'},
                              'foregroundSeconds': {'unit': 'seconds', 'value': foreground, 'availability': 'available'}}
        result = tool.compare([self.bundle('old-cpu', [old]), self.bundle('new-cpu', [new])])
        self.assertEqual([c['appTotalCPUSecondsPerForegroundHour'] for c in result['cohorts']], [[60.0], [60.0]])
        cpu = next(change for change in result['osChanges'] if change['metric'] == 'cpuSeconds')
        self.assertEqual(cpu['changePercent'], 100.0)
        self.assertEqual(cpu['evidence'], 'insufficient reports')
        new['begin'] = '2026-10-03T09:00:00Z'
        mismatch = tool.compare([self.bundle('old-cpu', [old]), self.bundle('new-cpu', [new])])
        self.assertFalse(mismatch['osChanges'])
        self.assertTrue(any('interval lengths' in w for w in mismatch['warnings']))

    def test_untrusted_archives_and_schema_units(self):
        for extra in ('../escape', '/absolute', 'unexpected.txt'):
            result = tool.compare([self.bundle('attack', [report()], extra)])
            self.assertFalse(result['cohorts']); self.assertIn('archive entries', result['warnings'][0])
        row = report(); row['schema'] = 2
        self.assertFalse(tool.compare([self.bundle('future', [row])])['cohorts'])
        row = report(); row['metrics'] = {'cpuSeconds': {'unit': 'joules', 'value': 1, 'availability': 'available'}}
        self.assertFalse(tool.compare([self.bundle('unit', [row])])['cohorts'])
        path = self.root / 'corrupt.zip'; path.write_bytes(b'not a zip')
        self.assertFalse(tool.compare([path])['cohorts'])


if __name__ == '__main__': unittest.main()
