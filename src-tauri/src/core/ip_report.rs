//! Report this machine's IP to every proxy server so its port guardian whitelists the address.
//!
//! The guardian whitelists the source address of `GET /{proxy port}/{path}` on its HTTP port, so a
//! report must leave directly: sent through a proxy it would whitelist that proxy's exit instead.
//! Servers without a guardian simply fail, which is expected and only logged.

use crate::{
    config::Config,
    constants::timing,
    process::AsyncHandler,
    utils::network::{NetworkManager, ProxyType},
};
use clash_verge_logging::{Type, logging};
use serde_yaml_ng::{Mapping, Value};
use std::{collections::BTreeSet, net::IpAddr};
use tokio::{sync::Notify, time::MissedTickBehavior};

static WAKE: Notify = Notify::const_new();

/// Asks for a report round; requests made while one is running coalesce into one more round.
pub fn request() {
    WAKE.notify_one();
}

pub fn start() {
    AsyncHandler::spawn(|| async {
        let mut ticker = tokio::time::interval(timing::IP_REPORT_INTERVAL);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = ticker.tick() => {}
                () = WAKE.notified() => ticker.reset(),
            }
            report_all().await;
        }
    });
}

async fn report_all() {
    let verge = Config::verge().await.latest_arc();
    if !verge.enable_ip_report.unwrap_or(false) {
        return;
    }
    let Some(report_port) = verge.ip_report_port else {
        return;
    };
    let path = verge
        .ip_report_path
        .as_deref()
        .unwrap_or_default()
        .trim()
        .trim_matches('/')
        .to_owned();
    drop(verge);
    if path.is_empty() {
        return;
    }

    let servers = match &Config::runtime().await.latest_arc().config {
        Some(config) => proxy_servers(config),
        None => return,
    };
    futures::future::join_all(
        servers
            .iter()
            .map(|(host, proxy_port)| report(host, report_port, *proxy_port, &path)),
    )
    .await;
}

async fn report(host: &str, report_port: u16, proxy_port: u16, path: &str) {
    let authority = if host.contains(':') {
        format!("[{host}]:{report_port}")
    } else {
        format!("{host}:{report_port}")
    };
    let url = format!("http://{authority}/{proxy_port}/{path}");
    let result = NetworkManager::new()
        .get(&url, ProxyType::None, Some(timing::IP_REPORT_TIMEOUT_SECS), None, false)
        .await;
    match result {
        // Any other body is the guardian's catch-all page: a wrong path or port.
        Ok(resp) if resp.status().is_success() => match resp.text().trim().parse::<IpAddr>() {
            Ok(ip) => logging!(
                info,
                Type::Network,
                "reported {ip} to {authority} for port {proxy_port}"
            ),
            Err(_) => logging!(
                debug,
                Type::Network,
                "{authority} did not accept the report for port {proxy_port}"
            ),
        },
        Ok(resp) => logging!(
            debug,
            Type::Network,
            "{authority} answered the report for port {proxy_port} with {}",
            resp.status()
        ),
        Err(error) => logging!(
            debug,
            Type::Network,
            "could not report to {authority} for port {proxy_port}: {error:#}"
        ),
    }
}

/// Every distinct `(server, port)` among the config's proxies.
fn proxy_servers(config: &Mapping) -> BTreeSet<(std::string::String, u16)> {
    let Some(proxies) = config.get("proxies").and_then(Value::as_sequence) else {
        return BTreeSet::new();
    };
    proxies
        .iter()
        .filter_map(|proxy| {
            let server = proxy.get("server")?.as_str()?.trim();
            let port = match proxy.get("port")? {
                Value::Number(port) => u16::try_from(port.as_u64()?).ok()?,
                Value::String(port) => port.trim().parse().ok()?,
                _ => return None,
            };
            (!server.is_empty()).then(|| (server.to_owned(), port))
        })
        .collect()
}

/// Sends traffic to the proxy servers directly, so reports made while TUN is on bypass the proxies.
pub fn prepend_direct_rules(mut config: Mapping) -> Mapping {
    let hosts: BTreeSet<_> = proxy_servers(&config).into_iter().map(|(host, _)| host).collect();
    if hosts.is_empty() {
        return config;
    }
    let mut rules: Vec<Value> = hosts
        .iter()
        .map(|host| {
            Value::from(match host.parse::<IpAddr>() {
                Ok(IpAddr::V4(ip)) => format!("IP-CIDR,{ip}/32,DIRECT,no-resolve"),
                Ok(IpAddr::V6(ip)) => format!("IP-CIDR6,{ip}/128,DIRECT,no-resolve"),
                Err(_) => format!("DOMAIN,{host},DIRECT"),
            })
        })
        .collect();
    if let Some(Value::Sequence(existing)) = config.remove("rules") {
        rules.extend(existing);
    }
    config.insert("rules".into(), Value::Sequence(rules));
    config
}
