# Only the affected Android packages get the compatibility route. Preserve
# every other match condition, rule ordering and explicit non-proxy policy.
def google_play_direct_fallback:
  def play_package:
    . == "com.android.vending"
      or . == "com.google.android.gms"
      or . == "com.google.android.gsf";
  def packages:
    .package_name | if type == "array" then .
      elif type == "string" then [.] else [] end;
  if any(.outbounds[]?; .type == "direct" and .tag == "direct") then
    .route.rules |= map(
      . as $rule
      | if ((.outbound == "proxy" or .outbound == "google-proxy")
          and (.invert != true) and (.type != "logical")
          and (.action == null or .action == "route")) then
          (packages | map(select(play_package))) as $play
          | (packages | map(select(play_package | not))) as $other
          | if ($play | length) == 0 then .
            else (.package_name = $play | .outbound = "direct"),
              (if ($other | length) > 0 then
                $rule | .package_name = $other
               else empty end)
            end
        else . end)
  else . end;
