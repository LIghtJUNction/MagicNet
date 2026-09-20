#!/usr/bin/env python3
"""Exercise the real reflection bridge against unavailable/malformed framework services."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUB = '''package android.net;
import java.util.*;
public class OplusNetworkingControlManager {
 public static Object response = new HashMap<Integer,Integer>();
 public static int writes;
 public static OplusNetworkingControlManager getOplusNetworkingControlManager() {
  return new OplusNetworkingControlManager();
 }
 public Object getPolicyList() { return response; }
 public void setUidPolicy(int uid, int policy) { writes++; }
}'''
TEST = '''package io.github.magicnet;
import java.io.*;
import java.util.*;
import android.net.OplusNetworkingControlManager;
public class BridgeTest {
 static String run(String... args) throws Exception {
  ByteArrayOutputStream buffer = new ByteArrayOutputStream();
  PrintStream previous = System.out;
  try { System.setOut(new PrintStream(buffer, true, "UTF-8")); NetworkPolicyBridge.main(args); }
  finally { System.setOut(previous); }
  return buffer.toString("UTF-8");
 }
 public static void main(String[] args) throws Exception {
  Map<Integer,Integer> map = new HashMap<>(); map.put(12001,4); map.put(13002,2);
  OplusNetworkingControlManager.response=map;
  String value=run("inspect","oplus");
  if (!value.contains("\\\"uid\\\":12001") || !value.contains("\\\"uid\\\":13002")) throw new AssertionError(value);
  if (!run("inspect","android").contains("provider_unsupported")) throw new AssertionError("missing provider promoted to success");
  OplusNetworkingControlManager.response=null;
  if (!run("inspect","oplus").contains("observation_failed")) throw new AssertionError("lost service promoted to success");
  Map<String,String> wrong = new HashMap<>(); wrong.put("unexpected","schema");
  OplusNetworkingControlManager.response=wrong;
  if (!run("inspect","oplus").contains("observation_failed")) throw new AssertionError("invalid schema accepted");
  OplusNetworkingControlManager.response=map;
  if (!run("allow","oplus","12001","4").contains("invalid_request")) throw new AssertionError("unexpected write accepted");
  if (OplusNetworkingControlManager.writes != 0) throw new AssertionError("read-only bridge changed policy");
 }
}'''


class BridgeTests(unittest.TestCase):
    def test_reflection_boundary_and_read_only_contract(self):
        with tempfile.TemporaryDirectory(prefix="magicnet-policy-test-") as raw:
            root = Path(raw)
            stub = root / "android/net/OplusNetworkingControlManager.java"
            harness = root / "io/github/magicnet/BridgeTest.java"
            stub.parent.mkdir(parents=True)
            harness.parent.mkdir(parents=True)
            stub.write_text(STUB)
            harness.write_text(TEST)
            subprocess.run([
                "javac", "--release", "8", "-Xlint:-options", "-d", str(root),
                str(ROOT / "crates/magicnet-cli/android/NetworkPolicyBridge.java"),
                str(stub), str(harness),
            ], check=True, timeout=30)
            subprocess.run(["java", "-cp", str(root), "io.github.magicnet.BridgeTest"],
                           check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
