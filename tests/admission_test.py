import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "proxy"))
from admission import Admission


class AdmissionTest(unittest.TestCase):
    def test_memory_and_flow_pressure(self):
        budget = Admission(capacity=10, max_flows=2)
        self.assertTrue(budget.reserve("one", 8))
        self.assertFalse(budget.reserve("two", 3))
        self.assertFalse(budget.reserve("one", 1))
        self.assertTrue(budget.reserve("two", 2))
        budget.release("one")
        budget.release("one")
        self.assertEqual(budget.used, 2)
        self.assertTrue(budget.reserve("three", 1))
        self.assertFalse(budget.reserve("four", 1))


if __name__ == "__main__":
    unittest.main()
