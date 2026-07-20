use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use crate::command_text_timeout;
use crate::utils::command_text_full_timeout;

const PING_SAMPLE_COUNT: &str = "10";
const ROUTE_GET_ARGS: &[&str] = &["-4", "route", "get", "1.1.1.1"];
const DEFAULT_ROUTE_FALLBACK_ARGS: &[&str] = &["-4", "route", "show", "table", "all", "default"];
const SPEEDTEST_BYTES: u64 = 5_242_880;
const SPEEDTEST_BUDGET_BYTES: u64 = SPEEDTEST_BYTES * 2;
const SPEEDTEST_DIRECT_URL: &str =
    "https://mirrors.tuna.tsinghua.edu.cn/archlinux/iso/latest/archlinux-x86_64.iso";
const SPEEDTEST_PROXY_URL: &str = "https://speed.cloudflare.com/__down?bytes=5242880";
const SPEEDTEST_PROXY: &str = "http://127.0.0.1:7892";
const SPEEDTEST_WRITE_OUT: &str = "http_code=%{http_code} size_download=%{size_download} time_total=%{time_total} speed_download=%{speed_download}";

#[derive(Clone, Copy, Debug, PartialEq)]
struct PingLatency {
    min: f64,
    avg: f64,
    max: f64,
    jitter: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct PingPacketLoss {
    transmitted: u64,
    received: u64,
    percent: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct HttpTiming {
    namelookup: f64,
    connect: f64,
    tls_appconnect: f64,
    starttransfer: f64,
    total: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct SpeedSample {
    bytes: u64,
    seconds: f64,
    bytes_per_second: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct SpeedtestResults {
    direct: Option<SpeedSample>,
    proxy: Option<SpeedSample>,
}

impl SpeedtestResults {
    fn succeeded(self) -> bool {
        self.direct.is_some() && self.proxy.is_some()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HttpProbePath {
    Direct,
    Proxy,
}

impl HttpProbePath {
    fn from_proxy(proxy: Option<&str>) -> Self {
        if proxy.is_some() {
            Self::Proxy
        } else {
            Self::Direct
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Proxy => "proxy",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct GatewayRoute {
    gateway: IpAddr,
    interface: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LinkQuality {
    Good,
    Degraded,
    Poor,
    Unavailable,
}

impl LinkQuality {
    fn as_str(self) -> &'static str {
        match self {
            Self::Good => "good",
            Self::Degraded => "degraded",
            Self::Poor => "poor",
            Self::Unavailable => "unavailable",
        }
    }
}

impl PingLatency {
    fn spread(self) -> f64 {
        self.max - self.min
    }
}

fn parse_default_gateway(output: &str) -> Option<GatewayRoute> {
    output.lines().find_map(|line| {
        let mut tokens = line.split_whitespace();
        if tokens.next()? != "default" {
            return None;
        }

        parse_gateway_route_tokens(tokens)
    })
}

fn parse_route_get_gateway(output: &str) -> Option<GatewayRoute> {
    output.lines().find_map(|line| {
        let mut tokens = line.split_whitespace();
        tokens.next()?.parse::<Ipv4Addr>().ok()?;
        let route = parse_gateway_route_tokens(tokens)?;
        route.gateway.is_ipv4().then_some(route)
    })
}

fn parse_gateway_route_tokens<'a>(
    mut tokens: impl Iterator<Item = &'a str>,
) -> Option<GatewayRoute> {
    let mut gateway = None;
    let mut interface = None;
    let mut valid = true;
    while let Some(token) = tokens.next() {
        match token {
            "via" => {
                if gateway.is_some() {
                    valid = false;
                    continue;
                }
                gateway = match tokens.next().and_then(|value| value.parse::<IpAddr>().ok()) {
                    Some(value) => Some(value),
                    None => {
                        valid = false;
                        None
                    }
                };
            }
            "dev" => {
                if interface.is_some() {
                    valid = false;
                    continue;
                }
                interface = match tokens.next() {
                    Some(value) if !value.is_empty() => Some(value.to_string()),
                    _ => {
                        valid = false;
                        None
                    }
                };
            }
            _ => {}
        }
    }

    match (valid, gateway, interface) {
        (true, Some(gateway), Some(interface)) => Some(GatewayRoute { gateway, interface }),
        _ => None,
    }
}

fn select_gateway_route(
    route_get_output: &str,
    fallback: impl FnOnce() -> String,
) -> Option<GatewayRoute> {
    parse_route_get_gateway(route_get_output).or_else(|| {
        let fallback_output = fallback();
        parse_default_gateway(&fallback_output)
    })
}

fn classify_link_quality(
    latency: Option<PingLatency>,
    loss: Option<PingPacketLoss>,
) -> LinkQuality {
    let (Some(latency), Some(loss)) = (latency, loss) else {
        return LinkQuality::Unavailable;
    };
    let spread = latency.spread();
    if loss.percent > 0.0
        || latency.avg >= 100.0
        || spread >= 300.0
        || latency.jitter.is_some_and(|jitter| jitter >= 50.0)
    {
        LinkQuality::Poor
    } else if latency.avg >= 30.0
        || latency.max >= 100.0
        || spread >= 75.0
        || latency.jitter.is_some_and(|jitter| jitter >= 15.0)
    {
        LinkQuality::Degraded
    } else {
        LinkQuality::Good
    }
}

fn print_gateway_probe() {
    println!("[Local Gateway]");
    let route_get_output = command_text_full_timeout("ip", ROUTE_GET_ARGS, Duration::from_secs(2));
    let route = select_gateway_route(&route_get_output, || {
        command_text_full_timeout("ip", DEFAULT_ROUTE_FALLBACK_ARGS, Duration::from_secs(2))
    });
    let Some(route) = route else {
        println!("gateway=unavailable");
        println!("interface=unavailable");
        println!("ping=unavailable");
        println!("latency_ms unavailable requested={PING_SAMPLE_COUNT}");
        println!("packet_loss unavailable requested={PING_SAMPLE_COUNT}");
        println!("link_quality_hint={}", LinkQuality::Unavailable.as_str());
        println!();
        return;
    };

    let gateway_text = route.gateway.to_string();
    println!("gateway={gateway_text}");
    println!("interface={}", route.interface);
    let Some(args) = ping_args(&gateway_text, None) else {
        println!("ping=unavailable");
        println!("latency_ms unavailable requested={PING_SAMPLE_COUNT}");
        println!("packet_loss unavailable requested={PING_SAMPLE_COUNT}");
        println!("link_quality_hint={}", LinkQuality::Unavailable.as_str());
        println!();
        return;
    };
    let ping = command_text_full_timeout("ping", &args, Duration::from_secs(5));
    println!("ping={}", ping_display_line(&ping));
    if let Some(line) = ping_latency_line(Some(&ping)) {
        println!("{line}");
    }
    if let Some(line) = ping_packet_loss_line(Some(&ping)) {
        println!("{line}");
    }
    let quality = classify_link_quality(parse_ping_latency(&ping), parse_ping_packet_loss(&ping));
    println!("link_quality_hint={}", quality.as_str());
    println!();
}

pub(crate) fn pingtest() -> Result<(), String> {
    println!("MagicNet connectivity test");
    println!("timeout=short");
    println!();
    print_gateway_probe();
    let results = [
        (
            "Baidu CN",
            ping_one("Baidu CN", "www.baidu.com", "https://www.baidu.com", None),
        ),
        (
            "Bilibili CN",
            ping_one(
                "Bilibili CN",
                "www.bilibili.com",
                "https://www.bilibili.com",
                None,
            ),
        ),
        (
            "Google Global",
            ping_one(
                "Google Global",
                "www.google.com",
                "https://www.google.com",
                Some("http://127.0.0.1:7892"),
            ),
        ),
        (
            "ChatGPT Global",
            ping_one(
                "ChatGPT Global",
                "chatgpt.com",
                "https://chatgpt.com",
                Some("http://127.0.0.1:7892"),
            ),
        ),
        (
            "GitHub Global",
            ping_one(
                "GitHub Global",
                "github.com",
                "https://github.com",
                Some("http://127.0.0.1:7892"),
            ),
        ),
    ];
    let total = results.len();
    let failed = collect_failed_names(results);
    println!("{}", summary_line(total, &failed));
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("pingtest failed: {}", failed.join(",")))
    }
}

pub(crate) fn speedtest() -> Result<(), String> {
    println!("MagicNet speed test");
    println!("{}", speedtest_budget_line());
    let results =
        run_speedtest_with(|_, args, timeout| command_text_full_timeout("curl", args, timeout));
    println!("{}", speed_line(HttpProbePath::Direct, results.direct));
    println!("{}", speed_line(HttpProbePath::Proxy, results.proxy));
    println!("{}", speedtest_summary_line(results));
    speedtest_result(results)
}

fn ping_one(name: &str, host: &str, url: &str, proxy: Option<&str>) -> bool {
    let http_path = HttpProbePath::from_proxy(proxy);
    println!("[{name}]");
    println!("host={host}");
    println!("path={}", path_label(proxy));
    if let Some(args) = ping_args(host, proxy) {
        let ping = command_text_full_timeout("ping", &args, Duration::from_secs(5));
        println!("ping={}", ping_display_line(&ping));
        if let Some(line) = ping_latency_line(Some(&ping)) {
            println!("{line}");
        }
        if let Some(line) = ping_packet_loss_line(Some(&ping)) {
            println!("{line}");
        }
    } else {
        println!("ping=skipped(proxy path)");
    }
    let curl_args = curl_args(url, proxy);
    let http = command_text_timeout("curl", &curl_args, Duration::from_secs(7));
    println!("http={http}");
    let reachable = http_probe_reachable(&http);
    println!("{}", http_timing_line(&http, reachable, http_path));
    println!("status={}", if reachable { "ok" } else { "failed" });
    println!();
    reachable
}

fn http_probe_reachable(output: &str) -> bool {
    output
        .split_whitespace()
        .find_map(|field| field.strip_prefix("http_code="))
        .and_then(|code| code.parse::<u16>().ok())
        .is_some_and(|code| (100..=599).contains(&code))
}

fn parse_http_timing(output: &str) -> Option<HttpTiming> {
    let mut namelookup = None;
    let mut connect = None;
    let mut tls_appconnect = None;
    let mut starttransfer = None;
    let mut total = None;
    for field in output.split_whitespace() {
        let Some((key, value)) = field.split_once('=') else {
            continue;
        };
        let slot = match key {
            "namelookup" => &mut namelookup,
            "connect" => &mut connect,
            "tls_appconnect" => &mut tls_appconnect,
            "starttransfer" => &mut starttransfer,
            "total" => &mut total,
            _ => continue,
        };
        if slot.is_some() {
            return None;
        }
        *slot = Some(parse_nonnegative_finite(value)?);
    }
    let timing = HttpTiming {
        namelookup: namelookup?,
        connect: connect?,
        tls_appconnect: tls_appconnect?,
        starttransfer: starttransfer?,
        total: total?,
    };
    if timing.namelookup > timing.connect
        || timing.connect > timing.tls_appconnect
        || timing.tls_appconnect > timing.starttransfer
        || timing.starttransfer > timing.total
    {
        return None;
    }
    Some(timing)
}

fn parse_nonnegative_finite(value: &str) -> Option<f64> {
    let value = value.parse::<f64>().ok()?;
    if !value.is_finite() || value < 0.0 {
        return None;
    }
    Some(normalize_zero(value))
}

fn parse_speed_sample(output: &str) -> Option<SpeedSample> {
    let mut http_code = None;
    let mut size_download = None;
    let mut time_total = None;
    let mut speed_download = None;

    for field in output.split_whitespace() {
        let Some((key, value)) = field.split_once('=') else {
            continue;
        };
        match key {
            "http_code" => {
                if http_code.is_some() {
                    return None;
                }
                http_code = Some(value.parse::<u16>().ok()?);
            }
            "size_download" => {
                if size_download.is_some() {
                    return None;
                }
                size_download = Some(value.parse::<u64>().ok()?);
            }
            "time_total" => {
                if time_total.is_some() {
                    return None;
                }
                time_total = Some(parse_positive_finite(value)?);
            }
            "speed_download" => {
                if speed_download.is_some() {
                    return None;
                }
                speed_download = Some(parse_positive_finite(value)?);
            }
            _ => {}
        }
    }

    let http_code = http_code?;
    let bytes = size_download?;
    if !(200..=299).contains(&http_code) || bytes != SPEEDTEST_BYTES {
        return None;
    }
    Some(SpeedSample {
        bytes,
        seconds: time_total?,
        bytes_per_second: speed_download?,
    })
}

fn parse_positive_finite(value: &str) -> Option<f64> {
    let value = value.parse::<f64>().ok()?;
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    Some(value)
}

fn speedtest_budget_line() -> String {
    format!("download_budget_bytes={SPEEDTEST_BUDGET_BYTES}")
}

fn speedtest_args(path: HttpProbePath) -> Vec<&'static str> {
    match path {
        HttpProbePath::Direct => vec![
            "-sS",
            "-L",
            "--range",
            "0-5242879",
            "--max-filesize",
            "5242880",
            "--noproxy",
            "*",
            "-o",
            "/dev/null",
            "--connect-timeout",
            "5",
            "--max-time",
            "25",
            "--write-out",
            SPEEDTEST_WRITE_OUT,
            SPEEDTEST_DIRECT_URL,
        ],
        HttpProbePath::Proxy => vec![
            "-sS",
            "-L",
            "--max-filesize",
            "5242880",
            "--noproxy",
            "",
            "-x",
            SPEEDTEST_PROXY,
            "-o",
            "/dev/null",
            "--connect-timeout",
            "5",
            "--max-time",
            "25",
            "--write-out",
            SPEEDTEST_WRITE_OUT,
            SPEEDTEST_PROXY_URL,
        ],
    }
}

fn run_speedtest_with(
    mut runner: impl FnMut(HttpProbePath, &[&str], Duration) -> String,
) -> SpeedtestResults {
    let direct_args = speedtest_args(HttpProbePath::Direct);
    let direct_output = runner(HttpProbePath::Direct, &direct_args, Duration::from_secs(30));
    let direct = parse_speed_sample(&direct_output);

    let proxy_args = speedtest_args(HttpProbePath::Proxy);
    let proxy_output = runner(HttpProbePath::Proxy, &proxy_args, Duration::from_secs(30));
    let proxy = parse_speed_sample(&proxy_output);

    SpeedtestResults { direct, proxy }
}

fn speed_line(path: HttpProbePath, sample: Option<SpeedSample>) -> String {
    match sample {
        Some(sample) => {
            let mbps = sample.bytes_per_second * 8.0 / 1_000_000.0;
            format!(
                "speed path={} bytes={} seconds={:.3} mbps={mbps:.3} status=ok",
                path.as_str(),
                sample.bytes,
                sample.seconds,
            )
        }
        None => format!(
            "speed path={} bytes=unavailable seconds=unavailable mbps=unavailable status=failed",
            path.as_str()
        ),
    }
}

fn speedtest_summary_line(results: SpeedtestResults) -> String {
    let direct = if results.direct.is_some() {
        "ok"
    } else {
        "failed"
    };
    let proxy = if results.proxy.is_some() {
        "ok"
    } else {
        "failed"
    };
    let status = if results.succeeded() { "ok" } else { "failed" };
    format!("speed_summary direct={direct} proxy={proxy} status={status}")
}

fn speedtest_result(results: SpeedtestResults) -> Result<(), String> {
    if results.succeeded() {
        return Ok(());
    }

    let mut failed = Vec::new();
    if results.direct.is_none() {
        failed.push(HttpProbePath::Direct.as_str());
    }
    if results.proxy.is_none() {
        failed.push(HttpProbePath::Proxy.as_str());
    }
    Err(format!("speedtest failed: {}", failed.join(",")))
}

fn normalize_zero(value: f64) -> f64 {
    if value == 0.0 {
        0.0
    } else {
        value
    }
}

fn http_timing_line(output: &str, reachable: bool, path: HttpProbePath) -> String {
    if !reachable {
        return "http_timing_ms unavailable".to_string();
    }
    let Some(timing) = parse_http_timing(output) else {
        return "http_timing_ms unavailable".to_string();
    };
    let dns = normalize_zero(timing.namelookup * 1_000.0);
    let tcp = normalize_zero((timing.connect - timing.namelookup) * 1_000.0);
    let secure_connect = normalize_zero((timing.tls_appconnect - timing.connect) * 1_000.0);
    let server = normalize_zero((timing.starttransfer - timing.tls_appconnect) * 1_000.0);
    let transfer = normalize_zero((timing.total - timing.starttransfer) * 1_000.0);
    let total = normalize_zero(timing.total * 1_000.0);
    if [dns, tcp, secure_connect, server, transfer, total]
        .iter()
        .any(|value| !value.is_finite() || *value < 0.0)
    {
        return "http_timing_ms unavailable".to_string();
    }
    match path {
        HttpProbePath::Direct => format!(
            "http_timing_ms dns={dns:.3} tcp={tcp:.3} secure_connect={secure_connect:.3} server={server:.3} transfer={transfer:.3} total={total:.3}"
        ),
        HttpProbePath::Proxy => format!(
            "http_timing_ms destination_dns=proxy_managed proxy_lookup={dns:.3} proxy_tcp={tcp:.3} tunnel_tls={secure_connect:.3} server={server:.3} transfer={transfer:.3} total={total:.3}"
        ),
    }
}

fn collect_failed_names<'a>(results: impl IntoIterator<Item = (&'a str, bool)>) -> Vec<&'a str> {
    results
        .into_iter()
        .filter_map(|(name, reachable)| (!reachable).then_some(name))
        .collect()
}

fn summary_line(total: usize, failed: &[&str]) -> String {
    let failed_names = if failed.is_empty() {
        "none".to_string()
    } else {
        failed.join(",")
    };
    format!(
        "summary ok={}/{} failed={failed_names}",
        total.saturating_sub(failed.len()),
        total
    )
}

fn path_label(proxy: Option<&str>) -> &'static str {
    if proxy.is_some() {
        "proxy"
    } else {
        "direct"
    }
}

fn parse_ping_latency(output: &str) -> Option<PingLatency> {
    let line = output
        .lines()
        .rev()
        .find(|line| is_ping_latency_summary(line))?;
    let (label, values) = line.split_once('=')?;
    let has_jitter = match label.trim() {
        "rtt min/avg/max/mdev" => true,
        "round-trip min/avg/max" => false,
        _ => return None,
    };
    let values = values.trim().strip_suffix("ms")?.trim();
    let mut values = values.split('/');
    let min = parse_latency_value(values.next()?)?;
    let avg = parse_latency_value(values.next()?)?;
    let max = parse_latency_value(values.next()?)?;
    let jitter = if has_jitter {
        Some(parse_latency_value(values.next()?)?)
    } else {
        None
    };
    if values.next().is_some() || min > avg || avg > max {
        return None;
    }
    Some(PingLatency {
        min,
        avg,
        max,
        jitter,
    })
}

fn is_ping_latency_summary(line: &str) -> bool {
    line.split_once('=').is_some_and(|(label, _)| {
        matches!(
            label.trim(),
            "rtt min/avg/max/mdev" | "round-trip min/avg/max"
        )
    })
}

fn parse_latency_value(value: &str) -> Option<f64> {
    let value = value.trim().parse::<f64>().ok()?;
    if !value.is_finite() || value < 0.0 {
        return None;
    }
    Some(if value == 0.0 { 0.0 } else { value })
}

fn ping_latency_line(output: Option<&str>) -> Option<String> {
    output.map(|output| match parse_ping_latency(output) {
        Some(latency) => {
            let jitter = latency
                .jitter
                .map_or_else(|| "unknown".to_string(), |value| format!("{value:.3}"));
            format!(
                "latency_ms min={:.3} avg={:.3} max={:.3} spread={:.3} jitter={jitter} requested={PING_SAMPLE_COUNT}",
                latency.min,
                latency.avg,
                latency.max,
                latency.spread()
            )
        }
        None => format!("latency_ms unavailable requested={PING_SAMPLE_COUNT}"),
    })
}

fn parse_ping_packet_loss(output: &str) -> Option<PingPacketLoss> {
    let line = output
        .lines()
        .rev()
        .find(|line| line.contains("packets transmitted") && line.contains("% packet loss"))?;
    let mut fields = line.split(',').map(str::trim);
    let transmitted = fields
        .next()?
        .strip_suffix(" packets transmitted")?
        .trim()
        .parse::<u64>()
        .ok()?;
    let received_field = fields.next()?;
    let received = received_field
        .strip_suffix(" packets received")
        .or_else(|| received_field.strip_suffix(" received"))?
        .trim()
        .parse::<u64>()
        .ok()?;
    let percent_text = fields.next()?.strip_suffix("% packet loss")?.trim();
    let (percent, tolerance) = parse_displayed_percent(percent_text)?;
    if transmitted == 0 || received > transmitted {
        return None;
    }
    let expected = (transmitted - received) as f64 * 100.0 / transmitted as f64;
    if (percent - expected).abs() > tolerance {
        return None;
    }
    Some(PingPacketLoss {
        transmitted,
        received,
        percent,
    })
}

fn parse_displayed_percent(value: &str) -> Option<(f64, f64)> {
    let decimal_places = match value.split_once('.') {
        Some((whole, fraction))
            if !whole.is_empty()
                && !fraction.is_empty()
                && whole.bytes().all(|byte| byte.is_ascii_digit())
                && fraction.bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            fraction.len()
        }
        None if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) => 0,
        _ => return None,
    };
    let percent = value.parse::<f64>().ok()?;
    if !percent.is_finite() || !(0.0..=100.0).contains(&percent) {
        return None;
    }
    let decimal_places = i32::try_from(decimal_places).ok()?;
    let tolerance = 0.5 * 10_f64.powi(-decimal_places) + 1e-9;
    Some((percent, tolerance))
}

fn ping_packet_loss_line(output: Option<&str>) -> Option<String> {
    output.map(|output| match parse_ping_packet_loss(output) {
        Some(loss) => format!(
            "packet_loss transmitted={} received={} percent={:.3} requested={PING_SAMPLE_COUNT}",
            loss.transmitted, loss.received, loss.percent
        ),
        None => format!("packet_loss unavailable requested={PING_SAMPLE_COUNT}"),
    })
}

fn ping_display_line(output: &str) -> &str {
    output
        .lines()
        .rev()
        .find(|line| is_ping_latency_summary(line))
        .or_else(|| output.lines().rev().find(|line| !line.trim().is_empty()))
        .unwrap_or("no output")
        .trim()
}

fn ping_args<'a>(host: &'a str, proxy: Option<&str>) -> Option<Vec<&'a str>> {
    proxy
        .is_none()
        .then(|| vec!["-c", PING_SAMPLE_COUNT, "-i", "0.2", "-W", "1", host])
}

fn curl_args<'a>(url: &'a str, proxy: Option<&'a str>) -> Vec<&'a str> {
    let mut args = vec![
        "-sS",
        "-I",
        "-o",
        "/dev/null",
        "--max-time",
        "5",
        "--write-out",
        "http_code=%{http_code} namelookup=%{time_namelookup} connect=%{time_connect} tls_appconnect=%{time_appconnect} starttransfer=%{time_starttransfer} total=%{time_total}",
    ];
    match proxy {
        Some(proxy_url) => {
            args.push("--noproxy");
            args.push("");
            args.push("-x");
            args.push(proxy_url);
        }
        None => {
            args.push("--noproxy");
            args.push("*");
        }
    }
    args.push(url);
    args
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::time::Duration;

    use super::{
        classify_link_quality, collect_failed_names, curl_args, http_probe_reachable,
        http_timing_line, parse_default_gateway, parse_http_timing, parse_ping_latency,
        parse_ping_packet_loss, parse_route_get_gateway, parse_speed_sample, path_label, ping_args,
        ping_display_line, ping_latency_line, ping_packet_loss_line, run_speedtest_with,
        select_gateway_route, speed_line, speedtest_args, speedtest_budget_line, speedtest_result,
        speedtest_summary_line, summary_line, GatewayRoute, HttpProbePath, HttpTiming, LinkQuality,
        PingLatency, PingPacketLoss, SpeedSample, SpeedtestResults, DEFAULT_ROUTE_FALLBACK_ARGS,
        ROUTE_GET_ARGS,
    };

    #[test]
    fn route_get_parser_accepts_real_android_ipv4_gateway_output() {
        let output =
            "1.1.1.1 via 192.168.32.1 dev wlan0 table wlan0 src 192.168.32.50 uid 0\n    cache";

        assert_eq!(
            parse_route_get_gateway(output),
            Some(GatewayRoute {
                gateway: "192.168.32.1".parse().expect("valid IPv4 test address"),
                interface: "wlan0".to_string(),
            })
        );
    }

    #[test]
    fn gateway_selection_prefers_valid_route_get_without_fallback() {
        let fallback_calls = Cell::new(0);
        let route = select_gateway_route(
            "1.1.1.1 via 192.168.32.1 dev wlan0 table wlan0 src 192.168.32.50 uid 0",
            || {
                fallback_calls.set(fallback_calls.get() + 1);
                "default via 10.0.0.1 dev rmnet_data0".to_string()
            },
        );

        assert_eq!(
            (route, fallback_calls.get()),
            (
                Some(GatewayRoute {
                    gateway: "192.168.32.1".parse().expect("valid IPv4 test address"),
                    interface: "wlan0".to_string(),
                }),
                0,
            )
        );
    }

    #[test]
    fn gateway_selection_falls_back_from_magicnet_tun_to_physical_default() {
        let route_get = "1.1.1.1 dev magicnet0 table 2022 src 172.19.0.1 uid 2000\n    cache";
        let route = select_gateway_route(route_get, || {
            "default dev dummy0 table dummy0 proto static scope link\n\
             default via 192.168.32.1 dev wlan0 table wlan0 proto static"
                .to_string()
        });

        assert_eq!(
            route,
            Some(GatewayRoute {
                gateway: "192.168.32.1".parse().expect("valid IPv4 test address"),
                interface: "wlan0".to_string(),
            })
        );
    }

    #[test]
    fn gateway_selection_returns_none_when_both_sources_lack_physical_gateway() {
        let route = select_gateway_route(
            "1.1.1.1 dev magicnet0 table 2022 src 172.19.0.1 uid 2000",
            || "default dev dummy0 table dummy0 proto static scope link".to_string(),
        );

        assert_eq!(route, None);
    }

    #[test]
    fn route_get_parser_rejects_malformed_and_duplicate_gateway_fields() {
        let invalid = [
            "not-an-ip via 192.168.32.1 dev wlan0",
            "1.1.1.1 dev wlan0",
            "1.1.1.1 via 192.168.32.1",
            "1.1.1.1 via nope dev wlan0",
            "1.1.1.1 via fe80::1 dev wlan0",
            "1.1.1.1 via 192.168.32.1 via 192.168.32.2 dev wlan0",
            "1.1.1.1 via 192.168.32.1 dev wlan0 dev rmnet_data0",
        ];

        assert!(invalid
            .iter()
            .all(|output| parse_route_get_gateway(output).is_none()));
    }

    #[test]
    fn gateway_probe_uses_ipv4_kernel_lookup_then_table_all_fallback() {
        assert_eq!(
            (ROUTE_GET_ARGS, DEFAULT_ROUTE_FALLBACK_ARGS),
            (
                &["-4", "route", "get", "1.1.1.1"][..],
                &["-4", "route", "show", "table", "all", "default"][..],
            )
        );
    }

    #[test]
    fn default_gateway_parser_accepts_ipv4_ipv6_and_extra_tokens() {
        assert_eq!(
            parse_default_gateway(
                "default via 192.168.32.1 dev wlan0 proto dhcp src 192.168.32.50 metric 600"
            ),
            Some(GatewayRoute {
                gateway: "192.168.32.1".parse().expect("valid IPv4 test address"),
                interface: "wlan0".to_string(),
            })
        );
        assert_eq!(
            parse_default_gateway("default via fe80::1 dev rmnet_data0 metric 1024 pref medium"),
            Some(GatewayRoute {
                gateway: "fe80::1".parse().expect("valid IPv6 test address"),
                interface: "rmnet_data0".to_string(),
            })
        );
    }

    #[test]
    fn default_gateway_parser_skips_invalid_candidate_for_later_valid_route() {
        assert_eq!(
            parse_default_gateway(
                "default dev rmnet_data0\ndefault via 10.0.0.1 dev wlan0 proto static"
            ),
            Some(GatewayRoute {
                gateway: "10.0.0.1".parse().expect("valid IPv4 test address"),
                interface: "wlan0".to_string(),
            })
        );
    }

    #[test]
    fn malformed_missing_and_duplicate_gateway_fields_are_rejected() {
        for output in [
            "default dev wlan0",
            "default via 192.168.1.1",
            "default via --help dev wlan0",
            "default via nope dev wlan0",
            "default via 192.168.1.1 via 192.168.1.2 dev wlan0",
            "default via 192.168.1.1 dev wlan0 dev eth0",
            "default via dev wlan0",
            "unreachable default via 192.168.1.1 dev wlan0",
        ] {
            assert_eq!(
                parse_default_gateway(output),
                None,
                "invalid route accepted: {output}"
            );
        }
    }

    #[test]
    fn link_quality_classifies_good_metrics() {
        assert_eq!(
            classify_link_quality(
                Some(PingLatency {
                    min: 5.0,
                    avg: 10.0,
                    max: 20.0,
                    jitter: Some(2.0),
                }),
                Some(PingPacketLoss {
                    transmitted: 10,
                    received: 10,
                    percent: 0.0,
                })
            ),
            LinkQuality::Good
        );
    }

    #[test]
    fn link_quality_degraded_boundaries_include_bsd_latency() {
        let no_loss = Some(PingPacketLoss {
            transmitted: 10,
            received: 10,
            percent: 0.0,
        });
        for latency in [
            PingLatency {
                min: 10.0,
                avg: 30.0,
                max: 40.0,
                jitter: None,
            },
            PingLatency {
                min: 26.0,
                avg: 29.0,
                max: 100.0,
                jitter: Some(1.0),
            },
            PingLatency {
                min: 1.0,
                avg: 20.0,
                max: 76.0,
                jitter: Some(1.0),
            },
            PingLatency {
                min: 5.0,
                avg: 10.0,
                max: 20.0,
                jitter: Some(15.0),
            },
        ] {
            assert_eq!(
                classify_link_quality(Some(latency), no_loss),
                LinkQuality::Degraded,
                "degraded boundary missed: {latency:?}"
            );
        }
    }

    #[test]
    fn link_quality_poor_for_packet_loss_and_inclusive_high_boundaries() {
        let no_loss = Some(PingPacketLoss {
            transmitted: 10,
            received: 10,
            percent: 0.0,
        });
        assert_eq!(
            classify_link_quality(
                Some(PingLatency {
                    min: 1.0,
                    avg: 2.0,
                    max: 3.0,
                    jitter: None,
                }),
                Some(PingPacketLoss {
                    transmitted: 10,
                    received: 9,
                    percent: 10.0,
                })
            ),
            LinkQuality::Poor
        );
        for latency in [
            PingLatency {
                min: 90.0,
                avg: 100.0,
                max: 110.0,
                jitter: Some(1.0),
            },
            PingLatency {
                min: 1.0,
                avg: 50.0,
                max: 301.0,
                jitter: Some(1.0),
            },
            PingLatency {
                min: 5.0,
                avg: 20.0,
                max: 30.0,
                jitter: Some(50.0),
            },
        ] {
            assert_eq!(
                classify_link_quality(Some(latency), no_loss),
                LinkQuality::Poor,
                "poor boundary missed: {latency:?}"
            );
        }
    }

    #[test]
    fn link_quality_is_unavailable_when_either_metric_is_missing() {
        let latency = Some(PingLatency {
            min: 1.0,
            avg: 2.0,
            max: 3.0,
            jitter: None,
        });
        let loss = Some(PingPacketLoss {
            transmitted: 10,
            received: 10,
            percent: 0.0,
        });

        assert_eq!(classify_link_quality(None, loss), LinkQuality::Unavailable);
        assert_eq!(
            classify_link_quality(latency, None),
            LinkQuality::Unavailable
        );
    }

    #[test]
    fn link_quality_strings_are_stable() {
        assert_eq!(LinkQuality::Good.as_str(), "good");
        assert_eq!(LinkQuality::Degraded.as_str(), "degraded");
        assert_eq!(LinkQuality::Poor.as_str(), "poor");
        assert_eq!(LinkQuality::Unavailable.as_str(), "unavailable");
    }

    #[test]
    fn direct_path_uses_ten_ping_samples() {
        assert_eq!(
            ping_args("www.baidu.com", None),
            Some(vec!["-c", "10", "-i", "0.2", "-W", "1", "www.baidu.com"])
        );
    }

    #[test]
    fn proxy_path_skips_ping() {
        let proxy = Some("http://127.0.0.1:7892");

        assert_eq!(
            (
                path_label(proxy),
                ping_args("github.com", proxy),
                ping_latency_line(None),
                ping_packet_loss_line(None)
            ),
            ("proxy", None, None, None)
        );
    }

    #[test]
    fn http_probe_path_tracks_ping_one_proxy_argument() {
        assert_eq!(
            (
                HttpProbePath::from_proxy(None),
                HttpProbePath::from_proxy(Some("http://127.0.0.1:7892")),
            ),
            (HttpProbePath::Direct, HttpProbePath::Proxy)
        );
    }

    #[test]
    fn linux_ping_statistics_parse_mdev_as_jitter() {
        assert_eq!(
            parse_ping_latency("rtt min/avg/max/mdev = 12.125/20.250/31.500/4.375 ms"),
            Some(PingLatency {
                min: 12.125,
                avg: 20.25,
                max: 31.5,
                jitter: Some(4.375),
            })
        );
    }

    #[test]
    fn bsd_ping_statistics_parse_without_jitter() {
        assert_eq!(
            parse_ping_latency("round-trip min/avg/max = 1/2/3 ms"),
            Some(PingLatency {
                min: 1.0,
                avg: 2.0,
                max: 3.0,
                jitter: None,
            })
        );
    }

    #[test]
    fn ping_statistics_accept_surrounding_space_and_decimal_values() {
        assert_eq!(
            parse_ping_latency(
                "10 packets transmitted\n  round-trip min/avg/max = 0.125 / 2.500 / 9.875 ms  \n"
            ),
            Some(PingLatency {
                min: 0.125,
                avg: 2.5,
                max: 9.875,
                jitter: None,
            })
        );
    }

    #[test]
    fn invalid_ping_statistics_are_rejected() {
        for output in [
            "",
            "timeout after 5000ms",
            "rtt min/avg/max/mdev = 1/2/3 ms",
            "round-trip min/avg/max = 1/2/3/4 ms",
            "rtt min/avg/max/mdev = -1/2/3/1 ms",
            "rtt min/avg/max/mdev = 1/NaN/3/1 ms",
            "rtt min/avg/max/mdev = 1/2/inf/1 ms",
            "rtt min/avg/max/mdev = 1/2/3/-inf ms",
            "rtt min/avg/max/mdev = 2/1/3/1 ms",
            "rtt min/avg/max/mdev = 1/3/2/1 ms",
        ] {
            assert_eq!(
                parse_ping_latency(output),
                None,
                "unexpected valid statistics: {output}"
            );
        }
    }

    #[test]
    fn latency_lines_use_fixed_decimals_and_safe_unavailable_fallback() {
        assert_eq!(
            (
                ping_latency_line(Some(
                    "rtt min/avg/max/mdev = 1/2.25/4.5/0.125 ms"
                )),
                ping_latency_line(Some("round-trip min/avg/max = 1/2.25/4.5 ms")),
                ping_latency_line(Some("timeout after 5000ms"))
            ),
            (
                Some("latency_ms min=1.000 avg=2.250 max=4.500 spread=3.500 jitter=0.125 requested=10".to_string()),
                Some("latency_ms min=1.000 avg=2.250 max=4.500 spread=3.500 jitter=unknown requested=10".to_string()),
                Some("latency_ms unavailable requested=10".to_string())
            )
        );
    }

    #[test]
    fn linux_and_bsd_packet_loss_summaries_are_parsed() {
        assert_eq!(
            (
                parse_ping_packet_loss(
                    "10 packets transmitted, 9 received, 10% packet loss, time 1806ms"
                ),
                parse_ping_packet_loss(
                    "10 packets transmitted, 9 packets received, 10.0% packet loss"
                )
            ),
            (
                Some(PingPacketLoss {
                    transmitted: 10,
                    received: 9,
                    percent: 10.0,
                }),
                Some(PingPacketLoss {
                    transmitted: 10,
                    received: 9,
                    percent: 10.0,
                })
            )
        );
    }

    #[test]
    fn packet_loss_parser_accepts_zero_partial_total_and_displayed_rounding() {
        for (output, expected) in [
            (
                "10 packets transmitted, 10 received, 0% packet loss",
                PingPacketLoss {
                    transmitted: 10,
                    received: 10,
                    percent: 0.0,
                },
            ),
            (
                "10 packets transmitted, 5 received, 50.0% packet loss",
                PingPacketLoss {
                    transmitted: 10,
                    received: 5,
                    percent: 50.0,
                },
            ),
            (
                "10 packets transmitted, 0 received, 100% packet loss",
                PingPacketLoss {
                    transmitted: 10,
                    received: 0,
                    percent: 100.0,
                },
            ),
            (
                "3 packets transmitted, 2 received, 33% packet loss",
                PingPacketLoss {
                    transmitted: 3,
                    received: 2,
                    percent: 33.0,
                },
            ),
        ] {
            assert_eq!(
                parse_ping_packet_loss(output),
                Some(expected),
                "valid summary rejected: {output}"
            );
        }
    }

    #[test]
    fn malformed_inconsistent_and_nonfinite_packet_loss_is_rejected() {
        for output in [
            "timeout after 5000ms",
            "packets transmitted, 9 received, 10% packet loss",
            "0 packets transmitted, 0 received, 0% packet loss",
            "10 packets transmitted, 11 received, 0% packet loss",
            "10 packets transmitted, 9 received, 20% packet loss",
            "10 packets transmitted, 9 received, 101% packet loss",
            "10 packets transmitted, 9 received, -10% packet loss",
            "10 packets transmitted, 9 received, NaN% packet loss",
            "10 packets transmitted, 9 received, inf% packet loss",
            "10 packets transmitted, 9 received, 10.% packet loss",
            "10 packets transmitted, 9 received, 10.0 percent packet loss",
        ] {
            assert_eq!(
                parse_ping_packet_loss(output),
                None,
                "invalid summary accepted: {output}"
            );
        }
    }

    #[test]
    fn packet_loss_lines_are_stable_and_unavailable_on_timeout() {
        assert_eq!(
            (
                ping_packet_loss_line(Some("10 packets transmitted, 9 received, 10% packet loss")),
                ping_packet_loss_line(Some("timeout after 5000ms"))
            ),
            (
                Some(
                    "packet_loss transmitted=10 received=9 percent=10.000 requested=10".to_string()
                ),
                Some("packet_loss unavailable requested=10".to_string())
            )
        );
    }

    #[test]
    fn concise_ping_display_prefers_latency_then_final_nonempty_line() {
        assert_eq!(
            (
                ping_display_line(
                    "10 packets transmitted, 9 received, 10% packet loss\nrtt min/avg/max/mdev = 1/2/3/0.5 ms\nwarning"
                ),
                ping_display_line(
                    "10 packets transmitted, 9 received, 10% packet loss\n\n"
                ),
                ping_display_line("timeout after 5000ms")
            ),
            (
                "rtt min/avg/max/mdev = 1/2/3/0.5 ms",
                "10 packets transmitted, 9 received, 10% packet loss",
                "timeout after 5000ms"
            )
        );
    }

    #[test]
    fn direct_path_label_and_curl_have_no_proxy_or_fail_flag() {
        let args = curl_args("https://www.baidu.com", None);

        assert_eq!(path_label(None), "direct");
        assert!(args.windows(2).any(|pair| pair == ["--noproxy", "*"]));
        assert!(!args.contains(&"-x"));
        assert!(!args.contains(&"-f"));
    }

    #[test]
    fn proxy_curl_uses_proxy_without_fail_flag() {
        let args = curl_args("https://chatgpt.com", Some("http://127.0.0.1:7892"));

        assert!(args
            .windows(2)
            .any(|pair| pair == ["-x", "http://127.0.0.1:7892"]));
        assert!(args.windows(2).any(|pair| pair == ["--noproxy", ""]));
        assert!(!args.windows(2).any(|pair| pair == ["--noproxy", "*"]));
        assert!(!args.contains(&"-f"));
    }

    #[test]
    fn curl_write_out_has_stable_timing_fields() {
        let args = curl_args("https://github.com", Some("http://127.0.0.1:7892"));
        let write_out = args
            .windows(2)
            .find(|pair| pair[0] == "--write-out")
            .map(|pair| pair[1])
            .expect("curl arguments must include --write-out");

        assert!(write_out.contains("http_code=%{http_code}"));
        assert!(write_out.contains("namelookup=%{time_namelookup}"));
        assert!(write_out.contains("connect=%{time_connect}"));
        assert!(write_out.contains("tls_appconnect=%{time_appconnect}"));
        assert!(write_out.contains("starttransfer=%{time_starttransfer}"));
        assert!(write_out.contains("total=%{time_total}"));
    }

    #[test]
    fn http_timing_parser_is_field_order_independent() {
        assert_eq!(
            (
                parse_http_timing(
                    "http_code=200 namelookup=0.010 connect=0.030 tls_appconnect=0.080 starttransfer=0.200 total=0.250"
                ),
                parse_http_timing(
                    "total=0.250 starttransfer=0.200 http_code=200 tls_appconnect=0.080 connect=0.030 namelookup=0.010"
                )
            ),
            (
                Some(HttpTiming {
                    namelookup: 0.010,
                    connect: 0.030,
                    tls_appconnect: 0.080,
                    starttransfer: 0.200,
                    total: 0.250,
                }),
                Some(HttpTiming {
                    namelookup: 0.010,
                    connect: 0.030,
                    tls_appconnect: 0.080,
                    starttransfer: 0.200,
                    total: 0.250,
                })
            )
        );
    }

    #[test]
    fn speed_sample_parser_accepts_exact_success() {
        assert_eq!(
            parse_speed_sample(
                "http_code=206 size_download=5242880 time_total=2.000 speed_download=2621440"
            ),
            Some(SpeedSample {
                bytes: 5_242_880,
                seconds: 2.0,
                bytes_per_second: 2_621_440.0,
            })
        );
    }

    #[test]
    fn speed_sample_parser_ignores_field_order_and_unrelated_curl_text() {
        assert_eq!(
            parse_speed_sample(
                "curl: notice speed_download=1310720 unrelated=value time_total=4 \
                 size_download=5242880 http_code=200"
            ),
            Some(SpeedSample {
                bytes: 5_242_880,
                seconds: 4.0,
                bytes_per_second: 1_310_720.0,
            })
        );
    }

    #[test]
    fn speed_sample_parser_rejects_invalid_or_ambiguous_measurements() {
        let invalid = [
            "http_code=404 size_download=5242880 time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242879 time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=0 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=-1 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=NaN speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=inf speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=2 speed_download=0",
            "http_code=200 size_download=5242880 time_total=2 speed_download=-1",
            "http_code=200 size_download=5242880 time_total=2 speed_download=NaN",
            "http_code=200 size_download=5242880 time_total=2 speed_download=inf",
            "size_download=5242880 time_total=2 speed_download=2621440",
            "http_code=200 time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242880 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=2",
            "http_code=200 http_code=206 size_download=5242880 time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242880 size_download=5242880 time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=2 time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=2 speed_download=2621440 speed_download=2621440",
            "http_code=two-hundred size_download=5242880 time_total=2 speed_download=2621440",
            "http_code=200 size_download=five-mebibytes time_total=2 speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=fast speed_download=2621440",
            "http_code=200 size_download=5242880 time_total=2 speed_download=fast",
        ];

        assert!(invalid
            .iter()
            .all(|output| parse_speed_sample(output).is_none()));
    }

    #[test]
    fn speed_sample_parser_enforces_two_xx_status_boundaries() {
        for code in [200, 299] {
            let output = format!(
                "http_code={code} size_download=5242880 time_total=2 speed_download=2621440"
            );
            assert!(parse_speed_sample(&output).is_some());
        }
        for code in [199, 300] {
            let output = format!(
                "http_code={code} size_download=5242880 time_total=2 speed_download=2621440"
            );
            assert!(parse_speed_sample(&output).is_none());
        }
    }

    #[test]
    fn speedtest_budget_and_curl_arguments_are_hard_capped() {
        assert_eq!(speedtest_budget_line(), "download_budget_bytes=10485760");
        assert_eq!(
            speedtest_args(HttpProbePath::Direct),
            vec![
                "-sS",
                "-L",
                "--range",
                "0-5242879",
                "--max-filesize",
                "5242880",
                "--noproxy",
                "*",
                "-o",
                "/dev/null",
                "--connect-timeout",
                "5",
                "--max-time",
                "25",
                "--write-out",
                "http_code=%{http_code} size_download=%{size_download} time_total=%{time_total} speed_download=%{speed_download}",
                "https://mirrors.tuna.tsinghua.edu.cn/archlinux/iso/latest/archlinux-x86_64.iso",
            ]
        );
        assert_eq!(
            speedtest_args(HttpProbePath::Proxy),
            vec![
                "-sS",
                "-L",
                "--max-filesize",
                "5242880",
                "--noproxy",
                "",
                "-x",
                "http://127.0.0.1:7892",
                "-o",
                "/dev/null",
                "--connect-timeout",
                "5",
                "--max-time",
                "25",
                "--write-out",
                "http_code=%{http_code} size_download=%{size_download} time_total=%{time_total} speed_download=%{speed_download}",
                "https://speed.cloudflare.com/__down?bytes=5242880",
            ]
        );
        assert!(!speedtest_args(HttpProbePath::Direct).contains(&"-I"));
        assert!(!speedtest_args(HttpProbePath::Proxy).contains(&"-I"));
    }

    #[test]
    fn speedtest_output_is_stable_for_success_and_failure() {
        let sample = SpeedSample {
            bytes: 5_242_880,
            seconds: 2.5,
            bytes_per_second: 1_250_000.0,
        };

        assert_eq!(
            speed_line(HttpProbePath::Direct, Some(sample)),
            "speed path=direct bytes=5242880 seconds=2.500 mbps=10.000 status=ok"
        );
        assert_eq!(
            speed_line(HttpProbePath::Proxy, None),
            "speed path=proxy bytes=unavailable seconds=unavailable mbps=unavailable status=failed"
        );
        assert_eq!(
            speedtest_summary_line(SpeedtestResults {
                direct: Some(sample),
                proxy: None,
            }),
            "speed_summary direct=ok proxy=failed status=failed"
        );
        assert_eq!(
            speedtest_summary_line(SpeedtestResults {
                direct: Some(sample),
                proxy: Some(sample),
            }),
            "speed_summary direct=ok proxy=ok status=ok"
        );
    }

    #[test]
    fn speedtest_runner_always_runs_direct_then_proxy_with_outer_timeout() {
        let calls = Cell::new(0);
        let results = run_speedtest_with(|path, args, timeout| {
            let call = calls.get();
            calls.set(call + 1);
            assert_eq!(call, if path == HttpProbePath::Direct { 0 } else { 1 });
            assert_eq!(args, speedtest_args(path).as_slice());
            assert_eq!(timeout, Duration::from_secs(30));
            match path {
                HttpProbePath::Direct => {
                    "http_code=503 size_download=5242880 time_total=2 speed_download=2621440"
                        .to_string()
                }
                HttpProbePath::Proxy => {
                    "http_code=200 size_download=5242880 time_total=4 speed_download=1310720"
                        .to_string()
                }
            }
        });

        assert_eq!(calls.get(), 2);
        assert_eq!(
            results,
            SpeedtestResults {
                direct: None,
                proxy: Some(SpeedSample {
                    bytes: 5_242_880,
                    seconds: 4.0,
                    bytes_per_second: 1_310_720.0,
                }),
            }
        );
    }

    #[test]
    fn speedtest_result_fails_when_either_path_is_unavailable() {
        let sample = SpeedSample {
            bytes: 5_242_880,
            seconds: 2.0,
            bytes_per_second: 2_621_440.0,
        };

        assert_eq!(
            speedtest_result(SpeedtestResults {
                direct: Some(sample),
                proxy: Some(sample),
            }),
            Ok(())
        );
        assert_eq!(
            speedtest_result(SpeedtestResults {
                direct: None,
                proxy: Some(sample),
            }),
            Err("speedtest failed: direct".to_string())
        );
        assert_eq!(
            speedtest_result(SpeedtestResults {
                direct: None,
                proxy: None,
            }),
            Err("speedtest failed: direct,proxy".to_string())
        );
    }

    #[test]
    fn direct_http_timing_line_keeps_existing_phase_fields() {
        assert_eq!(
            http_timing_line(
                "http_code=200 namelookup=0.010 connect=0.030 tls_appconnect=0.080 starttransfer=0.200 total=0.250",
                true,
                HttpProbePath::Direct,
            ),
            "http_timing_ms dns=10.000 tcp=20.000 secure_connect=50.000 server=120.000 transfer=50.000 total=250.000"
        );
    }

    #[test]
    fn proxy_http_timing_line_labels_proxy_and_tunnel_phases() {
        assert_eq!(
            http_timing_line(
                "http_code=200 namelookup=0.010 connect=0.030 tls_appconnect=0.080 starttransfer=0.200 total=0.250",
                true,
                HttpProbePath::Proxy,
            ),
            "http_timing_ms destination_dns=proxy_managed proxy_lookup=10.000 proxy_tcp=20.000 tunnel_tls=50.000 server=120.000 transfer=50.000 total=250.000"
        );
    }

    #[test]
    fn proxy_http_timing_line_omits_misleading_direct_phase_tokens() {
        let line = http_timing_line(
            "http_code=200 namelookup=0.010 connect=0.030 tls_appconnect=0.080 starttransfer=0.200 total=0.250",
            true,
            HttpProbePath::Proxy,
        );

        assert!(!line.split_whitespace().any(|field| {
            field
                .split_once('=')
                .is_some_and(|(name, _)| matches!(name, "dns" | "tcp" | "secure_connect"))
        }));
    }

    #[test]
    fn finite_cumulative_timings_that_overflow_milliseconds_are_unavailable() {
        assert_eq!(
            http_timing_line(
                "http_code=200 namelookup=1e308 connect=1e308 tls_appconnect=1e308 starttransfer=1e308 total=1e308",
                true,
                HttpProbePath::Direct,
            ),
            "http_timing_ms unavailable"
        );
    }

    #[test]
    fn zero_http_timings_normalize_negative_zero() {
        assert_eq!(
            http_timing_line(
                "http_code=200 namelookup=-0.0 connect=0 tls_appconnect=-0.000 starttransfer=0.0 total=-0",
                true,
                HttpProbePath::Direct,
            ),
            "http_timing_ms dns=0.000 tcp=0.000 secure_connect=0.000 server=0.000 transfer=0.000 total=0.000"
        );
    }

    #[test]
    fn malformed_missing_duplicate_nonfinite_and_nonmonotonic_timings_are_rejected() {
        for output in [
            "curl: connection failed",
            "http_code=200 namelookup=0.01 connect=0.02 tls_appconnect=0.03 starttransfer=0.04",
            "namelookup=0.01 namelookup=0.01 connect=0.02 tls_appconnect=0.03 starttransfer=0.04 total=0.05",
            "namelookup=nope connect=0.02 tls_appconnect=0.03 starttransfer=0.04 total=0.05",
            "namelookup=NaN connect=0.02 tls_appconnect=0.03 starttransfer=0.04 total=0.05",
            "namelookup=0.01 connect=inf tls_appconnect=0.03 starttransfer=0.04 total=0.05",
            "namelookup=-0.01 connect=0.02 tls_appconnect=0.03 starttransfer=0.04 total=0.05",
            "namelookup=0.02 connect=0.01 tls_appconnect=0.03 starttransfer=0.04 total=0.05",
            "namelookup=0.01 connect=0.03 tls_appconnect=0.02 starttransfer=0.04 total=0.05",
            "namelookup=0.01 connect=0.02 tls_appconnect=0.04 starttransfer=0.03 total=0.05",
            "namelookup=0.01 connect=0.02 tls_appconnect=0.03 starttransfer=0.05 total=0.04",
        ] {
            assert_eq!(
                parse_http_timing(output),
                None,
                "invalid timing accepted: {output}"
            );
        }
    }

    #[test]
    fn unreachable_or_invalid_http_timing_is_unavailable() {
        let failed = "http_code=000 namelookup=0.01 connect=0.02 tls_appconnect=0.03 starttransfer=0.04 total=0.05";

        assert_eq!(
            (
                http_timing_line(failed, http_probe_reachable(failed), HttpProbePath::Direct,),
                http_timing_line("curl: connection failed", true, HttpProbePath::Direct,),
                http_timing_line(failed, http_probe_reachable(failed), HttpProbePath::Proxy,),
                http_timing_line("curl: connection failed", true, HttpProbePath::Proxy,),
            ),
            (
                "http_timing_ms unavailable".to_string(),
                "http_timing_ms unavailable".to_string(),
                "http_timing_ms unavailable".to_string(),
                "http_timing_ms unavailable".to_string(),
            )
        );
    }

    #[test]
    fn valid_http_response_codes_are_reachable() {
        for code in [200, 204, 301, 403, 429] {
            let output =
                format!("http_code={code} tls_appconnect=0.010 starttransfer=0.020 total=0.030");
            assert!(
                http_probe_reachable(&output),
                "HTTP {code} should be reachable"
            );
        }
    }

    #[test]
    fn invalid_or_missing_http_response_codes_fail() {
        for output in [
            "http_code=000 tls_appconnect=0.000 starttransfer=0.000 total=0.000",
            "curl not available: No such file or directory",
            "tls_appconnect=0.000 starttransfer=0.000 total=0.000",
            "http_code=abc total=0.000",
            "http_code=99 total=0.000",
            "http_code=600 total=0.000",
            "timeout after 7000ms",
        ] {
            assert!(
                !http_probe_reachable(output),
                "unexpected success: {output}"
            );
        }
    }

    #[test]
    fn summaries_cover_all_success_and_mixed_failures() {
        assert_eq!(summary_line(5, &[]), "summary ok=5/5 failed=none");
        assert_eq!(
            summary_line(5, &["Baidu CN", "GitHub Global"]),
            "summary ok=3/5 failed=Baidu CN,GitHub Global"
        );
    }

    #[test]
    fn collecting_failures_does_not_short_circuit() {
        let calls = Cell::new(0);
        let results = ["one", "two", "three"].map(|name| {
            calls.set(calls.get() + 1);
            (name, name != "two")
        });

        assert_eq!(collect_failed_names(results), vec!["two"]);
        assert_eq!(calls.get(), 3);
    }
}
