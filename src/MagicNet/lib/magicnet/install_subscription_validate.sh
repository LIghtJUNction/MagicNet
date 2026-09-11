# shellcheck shell=ash
# Offline input gate. Runtime still resolves/pins DNS and validates redirects.
# The URL is read from a private file, never passed through eval or command argv.
[ "$#" = 1 ] && [ -f "$1" ] && [ ! -L "$1" ] || exit 1
url_awk() {
    if [ -n "${KWI_BB:-}" ]; then "$KWI_BB" awk "$@"; else awk "$@"; fi
}
LC_ALL=C url_awk '

    function ipv6_valid(value, part, halves, left, right, n, i, total) {
        if (value ~ /:::/) return 0
        n=split(value,halves,"::")
        if (n>2) return 0
        total=0
        for (i=1;i<=n;i++) {
            if (halves[i]=="") continue
            if (halves[i] ~ /^:|:$/) return 0
            left=split(halves[i],part,":")
            for (right=1;right<=left;right++)
                if (length(part[right])<1 || length(part[right])>4) return 0
            total+=left
        }
        return n==2 ? total<8 : total==8
    }
    NR != 1 { bad=1; next }
    {
        if ($0 !~ /^https:\/\// || $0 ~ /[[:space:]\\#]/) { bad=1; next }
        host=substr($0,9); sub(/[\/?].*$/, "", host)
        if (host == "" || host ~ /@/) { bad=1; next }
        if (host ~ /^\[/) {
            if (host !~ /^\[[0-9A-Fa-f:]+\](:[0-9]+)?$/) { bad=1; next }
            port=host; sub(/^.*\]/, "", port)
            sub(/^\[/, "", host); sub(/\].*$/, "", host)
            host=tolower(host)
            # Global-unicast IPv6 only; runtime performs the full address check.
            if (!ipv6_valid(host) || host !~ /^[23]/ || host ~ /^2001:0?db8:/) bad=1
        } else {
            port=host; sub(/^[^:]+/, "", port); sub(/:.*/, "", host)
            host=tolower(host)
            sub(/\.$/, "", host)
            if (host !~ /^[a-z0-9.-]+$/ || host !~ /\./ || host ~ /\.\./ ||
                host ~ /(^|\.)-/ || host ~ /-(\.|$)/ || host ~ /^\./ ||
                host ~ /\.(localhost|local|internal|invalid|test)\.?$/) bad=1
            if (length(host)>253) bad=1
            labels=split(host,label,".")
            for (i=1;i<=labels;i++) if (length(label[i])<1 || length(label[i])>63) bad=1
            if (host ~ /^[0-9.]+$/) {
                n=split(host,a,".")
                if (n != 4) bad=1
                for (i=1;i<=n;i++) if (a[i] == "" || a[i] > 255 || a[i] ~ /^0[0-9]/) bad=1
                if (a[1]==0 || a[1]==10 || a[1]==127 || a[1]>=224 ||
                    (a[1]==100 && a[2]>=64 && a[2]<=127) ||
                    (a[1]==169 && a[2]==254) || (a[1]==172 && a[2]>=16 && a[2]<=31) ||
                    (a[1]==192 && (a[2]==168 || (a[2]==0 && (a[3]==0 || a[3]==2)))) ||
                    (a[1]==198 && (a[2]==18 || a[2]==19 || (a[2]==51 && a[3]==100))) ||
                    (a[1]==203 && a[2]==0 && a[3]==113)) bad=1
            } else if (host ~ /\.[0-9]+\.?$/) bad=1
        }
        if (port != "") {
            if (port !~ /^:[0-9]+$/) bad=1
            sub(/^:/, "", port)
            if (length(port)>5 || (port+0)<1 || (port+0)>65535) bad=1
        }
        seen=1
    }
    END { exit (!seen || bad) ? 1 : 0 }
' "$1"
