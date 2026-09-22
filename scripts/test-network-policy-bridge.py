#!/usr/bin/env python3
"""Run the production reflection bridge with fake Binder services, not Android acceptance."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUBS = {
    "android/os/Process.java": """package android.os;
public class Process { public static int uid; public static int myUid() { return uid; } }
""",
    "android/os/IBinder.java": "package android.os; public interface IBinder {}",
    "android/os/ServiceManager.java": """package android.os;
public class ServiceManager {
 public static IBinder getService(String name) { return new IBinder() {}; }
} """,
    "android/content/pm/IPackageManager.java": """package android.content.pm;
public interface IPackageManager { String[] getPackagesForUid(int uid); }
""",
    "android/app/AppGlobals.java": """package android.app;
import android.content.pm.IPackageManager;
public class AppGlobals {
 public static String[] names = {"app.one", "app.shared"};
 public static IPackageManager getPackageManager() {
  return new IPackageManager() { public String[] getPackagesForUid(int uid) { return names; } };
 }
} """,
    "android/net/OplusNetworkingControlManager.java": """package android.net;
import java.util.*;
public class OplusNetworkingControlManager {
 public static Object response = new TreeMap<Integer,Integer>();
 public static int writes;
 public static boolean ignore, unavailable;
 public static OplusNetworkingControlManager getOplusNetworkingControlManager() {
  return unavailable ? null : new OplusNetworkingControlManager();
 }
 public Object getPolicyList() { return response; }
 @SuppressWarnings("unchecked")
 public void setUidPolicy(int uid, int policy) {
  writes++;
  if (!ignore) ((Map<Integer,Integer>)response).put(uid, policy);
 }
} """,
    "android/net/INetworkPolicyManager.java": """package android.net;
import java.util.*;
import android.os.IBinder;
public interface INetworkPolicyManager {
 int getUidPolicy(int uid);
 int[] getUidsWithPolicy(int policy);
 void setUidPolicy(int uid, int policy);
 class Stub {
  public static Map<Integer,Integer> values = new TreeMap<>();
  public static int writes;
  public static INetworkPolicyManager asInterface(IBinder binder) {
   return new INetworkPolicyManager() {
    public int getUidPolicy(int uid) { Integer value=values.get(uid); return value==null?0:value; }
    public int[] getUidsWithPolicy(int policy) {
     return values.keySet().stream().filter(k -> (values.get(k)&policy)!=0)
        .mapToInt(Integer::intValue).toArray();
    }
    public void setUidPolicy(int uid, int policy) { writes++; values.put(uid,policy); }
   };
  }
 }
} """,
}
HARNESS = r'''package io.github.magicnet;
import java.io.*;
import java.util.*;
import android.net.OplusNetworkingControlManager;
import android.net.INetworkPolicyManager;
public class BridgeTest {
 static String run(String... args) throws Exception {
  ByteArrayOutputStream buffer = new ByteArrayOutputStream();
  PrintStream previous = System.out;
  try { System.setOut(new PrintStream(buffer, true, "UTF-8")); NetworkPolicyBridge.main(args); }
  finally { System.setOut(previous); }
  return buffer.toString("UTF-8");
 }
 static void check(boolean ok, String reason) { if (!ok) throw new AssertionError(reason); }
 public static void main(String[] args) throws Exception {
  Map<Integer,Integer> map=new TreeMap<>(); map.put(12001,4); map.put(13002,2);
  OplusNetworkingControlManager.response=map;
  String result;
  switch (args[0]) {
   case "readonly":
    result=run("inspect","oplus");
    check(result.contains("\"uid\":12001") && result.contains("\"uid\":13002"), result);
    check(run("allow","oplus","12001","4").contains("invalid_request"), "legacy write accepted");
    check(OplusNetworkingControlManager.writes==0, "inspection wrote policies"); break;
   case "malformed":
    OplusNetworkingControlManager.response=Collections.singletonMap("private_uid", "private_error");
    result=run("inspect","oplus");
    check(!result.contains("private_"), "private framework text leaked"); break;
   case "unavailable":
    OplusNetworkingControlManager.unavailable=true; result=run("inspect","oplus"); break;
   case "repair_rollback":
    result=run("change","oplus","12001","4","0","app.one,app.shared");
    check(result.contains("\"configured_verified\":true") && map.get(12001)==0,result);
    result=run("change","oplus","12001","0","4","app.one,app.shared");
    check(map.get(12001)==4 && map.get(13002)==2,"rollback or unrelated policy changed");
    check(OplusNetworkingControlManager.writes==2,"wrong write count"); break;
   case "conflict":
    result=run("change","oplus","12001","2","0","app.one,app.shared");
    check(OplusNetworkingControlManager.writes==0,"stale observation changed policy"); break;
   case "shared_identity":
    result=run("change","oplus","12001","4","0","app.one");
    check(OplusNetworkingControlManager.writes==0,"unreviewed shared identity changed"); break;
   case "unprivileged":
    android.os.Process.uid=2000;
    result=run("change","oplus","12001","4","0","app.one,app.shared");
    check(OplusNetworkingControlManager.writes==0,"unprivileged write"); break;
   case "readback":
    OplusNetworkingControlManager.ignore=true;
    result=run("change","oplus","12001","4","0","app.one,app.shared");
    check(OplusNetworkingControlManager.writes==1,"unbounded repair loop"); break;
   case "unknown":
    for (String[] pair : new String[][] {{"3","0"},{"8","0"},{"-1","0"},{"0","-1"}}) {
     check(run("change","oplus","12001",pair[0],pair[1],"app.one,app.shared")
        .contains("repair_unsupported"),"unknown policy accepted");
    }
    check(OplusNetworkingControlManager.writes==0,"unknown policy written");
    result="{\"ok\":true}"; break;
   case "identity_classes":
    for (String uid : new String[] {"1000","20000","90000","99001","-1"}) {
     check(run("change","oplus",uid,"4","0","app.one,app.shared")
       .contains("repair_unsupported"),"non-application identity accepted");
    }
    map.put(112001,4);
    result=run("change","oplus","112001","4","0","app.one,app.shared");
    check(map.get(112001)==0 && map.get(12001)==4,"Android user scope lost"); break;
   case "android":
    INetworkPolicyManager.Stub.values.put(12001,5);
    INetworkPolicyManager.Stub.values.put(13002,1);
    result=run("change","android","12001","5","4","app.one,app.shared");
    check(result.contains("\"configured_verified\":true"),result);
    check(INetworkPolicyManager.Stub.values.get(12001)==4,"unrelated allow bit lost");
    check(INetworkPolicyManager.Stub.values.get(13002)==1,"other app altered");
    result=run("get","android","12001");
    check(result.contains("\"policy\":4"),"non-reject policy absent from exact query"); break;
   case "strict_args":
    for (String[] request : new String[][] {{},{"change"},{"change","oplus"},
       {"change","oplus","12001","4","0","app.shared,app.one"},
       {"change","oplus","12001","4","0","app.one,app.one"},
       {"change","oplus","12001","4","0","app.one;id"}}) {
     check(run(request).contains("\"ok\":false"),"invalid request accepted");
    }
    check(OplusNetworkingControlManager.writes==0,"malformed request changed policy");
    result="{\"ok\":true}"; break;
   default: throw new AssertionError("unknown scenario");
  }
  System.out.print(result);
 }
}'''


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="magicnet-policy-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        sources = [ROOT / "crates/magicnet-cli/android/NetworkPolicyBridge.java"]
        for name, content in {**STUBS, "io/github/magicnet/BridgeTest.java": HARNESS}.items():
            source = cls.root / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(content)
            sources.append(source)
        subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-d", str(cls.root),
                        *map(str, sources)], check=True, timeout=30)

    def scenario(self, name):
        result = subprocess.run(["java", "-cp", str(self.root),
                                 "io.github.magicnet.BridgeTest", name],
                                check=True, capture_output=True, text=True, timeout=15)
        return json.loads(result.stdout)

    def test_inspect_remains_read_only(self):
        self.assertTrue(self.scenario("readonly")["repair_supported"])

    def test_malformed_service_is_unknown_not_empty(self):
        self.assertEqual(self.scenario("malformed")["error"], "observation_failed")

    def test_lost_service_is_unknown(self):
        self.assertEqual(self.scenario("unavailable")["error"], "observation_failed")

    def test_real_adapter_writes_and_rolls_back_only_selected_identity(self):
        self.assertTrue(self.scenario("repair_rollback")["configured_verified"])

    def test_stale_policy_is_not_overwritten(self):
        self.assertEqual(self.scenario("conflict")["error"], "policy_conflict")

    def test_entire_shared_identity_must_match(self):
        self.assertEqual(self.scenario("shared_identity")["error"], "identity_conflict")

    def test_root_is_required_for_changes(self):
        self.assertEqual(self.scenario("unprivileged")["error"], "permission_denied")

    def test_ignored_write_is_not_reported_successful_or_retried_forever(self):
        self.assertEqual(self.scenario("readback")["error"], "repair_not_effective")

    def test_unknown_and_negative_policy_values_never_write(self):
        self.assertTrue(self.scenario("unknown")["ok"])

    def test_dynamic_uid_respects_android_users_and_excludes_sandbox(self):
        self.assertTrue(self.scenario("identity_classes")["configured_verified"])

    def test_aosp_repair_preserves_other_flags_and_exact_readback(self):
        self.assertEqual(self.scenario("android")["policy"], 4)

    def test_malformed_requests_do_not_write(self):
        self.assertTrue(self.scenario("strict_args")["ok"])

    def test_missing_framework_is_unsupported(self):
        with tempfile.TemporaryDirectory(prefix="magicnet-policy-missing-") as raw:
            subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-d", raw,
                            str(ROOT / "crates/magicnet-cli/android/NetworkPolicyBridge.java")],
                           check=True, timeout=30)
            result = subprocess.run(["java", "-cp", raw,
                                     "io.github.magicnet.NetworkPolicyBridge", "inspect", "oplus"],
                                    check=True, capture_output=True, text=True, timeout=15)
            self.assertEqual(json.loads(result.stdout)["error"], "provider_unsupported")


if __name__ == "__main__":
    unittest.main()
