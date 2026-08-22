import importlib.util
import json
import pathlib
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "t14-ps2-verification-state.py"
SPEC = importlib.util.spec_from_file_location("verification_state", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


def item(root, distro, kernel, fingerprint, current=False, native=True, patched=False):
    return {
        "root_uuid": root,
        "installation_id": root,
        "distribution": distro,
        "distribution_id": "fedora" if "Fedora" in distro else "linuxmint",
        "kernel": kernel,
        "boot_target_fingerprint": fingerprint,
        "current": current,
        "kernel_patched": patched,
        "native_configured": native,
        "remediation": "native-configured",
        "runtime_verified": False,
    }


class VerificationStateTests(unittest.TestCase):
    def setUp(self):
        self.fedora = item("fedora-root", "Fedora Linux 44", "7.1.8-t14ps2quirk1", "fedora-fp", True, True, True)
        self.mint = item("mint-root", "Linux Mint 22.3", "6.14.0-37-generic", "mint-fp")
        self.inventory = {"installations": [self.fedora, self.mint]}

    def test_verification_survives_switching_current_operating_system(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        self.fedora["current"] = False
        self.mint["current"] = True
        reconciled = MODULE.reconcile(self.inventory, state)
        self.assertTrue(reconciled["installations"][0]["runtime_verified"])
        self.assertFalse(reconciled["installations"][1]["runtime_verified"])

    def test_fedora_and_mint_can_both_be_recorded(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        self.fedora["current"] = False
        self.mint["current"] = True
        state = MODULE.record(self.inventory, state)
        reconciled = MODULE.reconcile(self.inventory, state)
        self.assertTrue(all(entry["runtime_verified"] for entry in reconciled["installations"]))

    def test_kernel_or_effective_boot_entry_change_invalidates(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        self.fedora["kernel"] = "7.1.9-200.fc44.x86_64"
        self.assertFalse(MODULE.reconcile(self.inventory, state)["installations"][0]["runtime_verified"])
        self.fedora["kernel"] = "7.1.8-t14ps2quirk1"
        self.fedora["boot_target_fingerprint"] = "changed"
        self.assertFalse(MODULE.reconcile(self.inventory, state)["installations"][0]["runtime_verified"])

    def test_distribution_or_remediation_method_change_invalidates(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        self.fedora["distribution_id"] = "replacement"
        self.assertFalse(MODULE.reconcile(self.inventory, state)["installations"][0]["runtime_verified"])
        self.fedora["distribution_id"] = "fedora"
        self.fedora["native_configured"] = False
        self.assertFalse(MODULE.reconcile(self.inventory, state)["installations"][0]["runtime_verified"])

    def test_removed_parameter_or_changed_root_invalidates(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        self.fedora["native_configured"] = False
        self.fedora["kernel_patched"] = False
        self.assertFalse(MODULE.reconcile(self.inventory, state)["installations"][0]["runtime_verified"])
        self.fedora["root_uuid"] = "replacement-root"
        self.fedora["installation_id"] = "replacement-root"
        self.assertFalse(MODULE.reconcile(self.inventory, state)["installations"][0]["runtime_verified"])

    def test_invalidate_removes_current_live_record(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        state = MODULE.invalidate(self.inventory, state)
        self.assertEqual({}, state["installations"])

    def test_atomic_state_round_trip(self):
        state = MODULE.record(self.inventory, MODULE.empty_state())
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "runtime.json"
            MODULE.write_state(path, state)
            self.assertEqual(state, MODULE.load_state(path))
            self.assertEqual(1, json.loads(path.read_text())["schema"])


if __name__ == "__main__":
    unittest.main()
