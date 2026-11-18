#!/usr/bin/env bash
# Port Guardian installer.
#
# Rejects every source on the given proxy ports except the IPs that Clash Verge's
# "IP Report" sends to http://<vps>:<http port>/<proxy port>/<path>.
#
#   install / reconfigure:  bash install.sh --ports 443/tcp,8443/udp [--http-port N] [--path SECRET]
#   show settings:          bash install.sh --show
#   uninstall:              bash install.sh --uninstall
set -euo pipefail

CONF_DIR=/etc/port-guardian
CONF_FILE=$CONF_DIR/guardian.json
STATE_FILE=$CONF_DIR/install.env
BIN=/usr/local/bin/port-guardian
UNIT=/etc/systemd/system/port-guardian.service
PASSPORT_NAME=clash-verge
GO_MIRROR=${GO_MIRROR:-https://go.dev}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
	cat <<'EOF'
Usage:
  install.sh --ports 443/tcp,8443/udp [--http-port PORT] [--path SECRET]
  install.sh --show
  install.sh --uninstall

Options:
  --ports      Proxy ports to guard, comma separated, each PORT or PORT/tcp or PORT/udp.
  --http-port  Port the client reports to. Defaults to the saved value or a random high port.
  --path       Report secret, letters, digits, '-' and '_', at least 8 characters.
               Defaults to the saved value or a random one.
  --force      Allow guarding a port that sshd listens on.

Use the same --http-port and --path on every VPS: the client sends one pair to all servers.
Set GO_MIRROR=https://golang.google.cn if go.dev is unreachable.
EOF
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

load_state() {
	OLD_HTTP_PORT='' OLD_PORTS='' OLD_PASS_PATH=''
	if [[ -f $STATE_FILE ]]; then
		# shellcheck disable=SC1090
		source "$STATE_FILE"
		OLD_HTTP_PORT=${HTTP_PORT:-} OLD_PORTS=${PORTS:-} OLD_PASS_PATH=${PASS_PATH:-}
	fi
}

# Removes only the rules port-guardian inserts, so unrelated rules on the same ports survive.
cleanup_rules() {
	local ports=$1 http_port=$2 item port proto reject_with rule
	local -a items
	IFS=, read -ra items <<<"$ports"
	for item in "${items[@]}"; do
		[[ -n $item ]] || continue
		port=${item%%/*}
		proto=${item#*/}
		[[ $proto == "$item" ]] && proto=tcp
		reject_with=tcp-reset
		[[ $proto == udp ]] && reject_with=icmp-port-unreachable
		while iptables -D INPUT -p "$proto" --dport "$port" -j REJECT --reject-with "$reject_with" 2>/dev/null; do :; done
	done
	iptables -S INPUT | while read -r rule; do
		if [[ $rule == *"--comment $PASSPORT_NAME"* && $rule == *"-j ACCEPT"* ]] ||
			[[ -n $http_port && $rule == *"-s "* && $rule == *"--dport $http_port "* && $rule == *"-j REJECT"* ]]; then
			# shellcheck disable=SC2086
			iptables ${rule/#-A/-D} || true
		fi
	done
}

stop_service() {
	if has_systemd; then
		systemctl stop port-guardian.service 2>/dev/null || true
	fi
	pkill -x port-guardian 2>/dev/null || true
}

firewall_allow() {
	local port=$1
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		info "ufw: allowing $port/tcp"
		ufw allow "$port/tcp" >/dev/null
	fi
	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		info "firewalld: allowing $port/tcp"
		firewall-cmd --permanent --add-port="$port/tcp" >/dev/null
		firewall-cmd --reload >/dev/null
	fi
}

public_ip() {
	curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<VPS_IP>'
}

show() {
	load_state
	[[ -n $OLD_PORTS ]] || die "port-guardian is not installed"
	local ip
	ip=$(public_ip)
	cat <<EOF

Guarded ports : $OLD_PORTS
Clash Verge  > Settings > System > IP Report
  Report Port : $OLD_HTTP_PORT
  Report Path : $OLD_PASS_PATH

Test from your computer (prints your IP when it works):
  curl http://$ip:$OLD_HTTP_PORT/${OLD_PORTS%%[/,]*}/$OLD_PASS_PATH

Logs: journalctl -u port-guardian -f
EOF
}

uninstall() {
	load_state
	info "stopping port-guardian"
	stop_service
	if has_systemd && [[ -f $UNIT ]]; then
		systemctl disable port-guardian.service >/dev/null 2>&1 || true
		rm -f "$UNIT"
		systemctl daemon-reload
	fi
	if [[ -n $OLD_PORTS ]]; then
		info "removing iptables rules"
		cleanup_rules "$OLD_PORTS" "$OLD_HTTP_PORT"
	fi
	rm -f "$BIN"
	rm -rf "$CONF_DIR"
	info "uninstalled; the proxy ports are open to everyone again"
}

install_deps() {
	local -a missing=()
	command -v iptables >/dev/null 2>&1 || missing+=(iptables)
	command -v sudo >/dev/null 2>&1 || missing+=(sudo)
	command -v curl >/dev/null 2>&1 || missing+=(curl)
	command -v tar >/dev/null 2>&1 || missing+=(tar)
	command -v pkill >/dev/null 2>&1 || missing+=(procps)
	[[ ${#missing[@]} -eq 0 ]] && return
	info "installing ${missing[*]}"
	if command -v apt-get >/dev/null 2>&1; then
		apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q "${missing[@]/procps/procps-ng}"
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q "${missing[@]/procps/procps-ng}"
	elif command -v apk >/dev/null 2>&1; then
		apk add -q "${missing[@]}"
	else
		die "please install: ${missing[*]}"
	fi
}

write_sources() {
	local dir=$1
	mkdir -p "$dir/guardian"
	cat >"$dir/go.mod" <<'EOF'
module port-guardian

go 1.20
EOF
	cat >"$dir/main.go" <<'EOF'
package main

import "port-guardian/guardian"

func main() {
	captain := &guardian.Captain{}
	captain.Run()
}
EOF
	cat >"$dir/guardian/guardian.go" <<'EOF'
package guardian

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type Guardian struct {
	Port      string     `json:"port"`
	Protocol  string     `json:"protocol"`
	Passports []Passport `json:"passports"`
}

type Passport struct {
	Path string `json:"path"`
	Name string `json:"name"`
	IP   string `json:"ip"`
}

// MarshalJSON never emits Path: it is the secret that grants whitelist access,
// so any future status/debug output must not leak it. Decoding still reads it.
func (p Passport) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Name string `json:"name"`
		IP   string `json:"ip"`
	}{Name: p.Name, IP: p.IP})
}

type Suspect struct {
	Time  time.Time `json:"time"`
	Count int       `json:"count"`
}

type Captain struct {
	HTTPort  string     `json:"httpPort"`
	Ports    []Guardian `json:"ports"`
	Suspects map[string]*Suspect
	mu       sync.Mutex
}

func normalizeProtocol(proto string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(proto)) {
	case "", "tcp":
		return "tcp", nil
	case "udp":
		return "udp", nil
	default:
		return "", fmt.Errorf("unsupported protocol %q, want tcp or udp", proto)
	}
}

func portRejectSpec(port, proto string) []string {
	spec := []string{"-p", proto, "--dport", port, "-j", "REJECT"}
	if proto == "udp" {
		return append(spec, "--reject-with", "icmp-port-unreachable")
	}
	return append(spec, "--reject-with", "tcp-reset")
}

func acceptSpec(ip, port, proto, name string) []string {
	return []string{"--source", ip, "-p", proto, "--dport", port, "-j", "ACCEPT", "-m", "comment", "--comment", name}
}

func banSpec(ip, httpPort string) []string {
	return []string{"--source", ip, "-p", "tcp", "--dport", httpPort, "-j", "REJECT"}
}

func (p *Captain) ensureBaseRules() error {
	for i := range p.Ports {
		g := &p.Ports[i]
		if err := iptablesInsert(portRejectSpec(g.Port, g.Protocol)...); err != nil {
			return err
		}
		for j := range g.Passports {
			passport := &g.Passports[j]
			if passport.IP == "" {
				continue
			}
			if err := iptablesInsert(acceptSpec(passport.IP, g.Port, g.Protocol, passport.Name)...); err != nil {
				return err
			}
			log.Printf("put ip %s in port %s/%s whitelist name %s ", passport.IP, g.Protocol, g.Port, passport.Name)
		}
	}
	return nil
}

func (p *Captain) allowIP(g *Guardian, passport *Passport, ip string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if passport.IP == ip {
		return nil
	}
	if passport.IP != "" {
		if err := iptablesDelete(acceptSpec(passport.IP, g.Port, g.Protocol, passport.Name)...); err != nil {
			return err
		}
	}
	if err := iptablesInsert(acceptSpec(ip, g.Port, g.Protocol, passport.Name)...); err != nil {
		return err
	}
	passport.IP = ip
	log.Printf("put ip %s in port %s/%s whitelist name %s ", ip, g.Protocol, g.Port, passport.Name)
	return nil
}

func (p *Captain) banIP(ip string) error {
	if err := iptablesInsert(banSpec(ip, p.HTTPort)...); err != nil {
		return err
	}
	log.Printf("put ip %s in port %s blacklist", ip, p.HTTPort)
	return nil
}

func (p *Captain) unbanIP(ip string) error {
	return iptablesDelete(banSpec(ip, p.HTTPort)...)
}

func (p *Captain) routes() error {
	for i := range p.Ports {
		for j, path := range p.Ports[i].Passports {
			r := fmt.Sprintf("/%s/%s", p.Ports[i].Port, path.Path)
			portIndex := i
			wayIndex := j
			http.HandleFunc(r, func(rw http.ResponseWriter, r *http.Request) {
				ip, _, err := net.SplitHostPort(r.RemoteAddr)
				if err != nil {
					rw.WriteHeader(http.StatusInternalServerError)
					rw.Write([]byte(err.Error()))
					return
				}
				if err := p.allowIP(&p.Ports[portIndex], &p.Ports[portIndex].Passports[wayIndex], ip); err != nil {
					rw.WriteHeader(http.StatusInternalServerError)
					rw.Write([]byte(err.Error()))
					return
				}
				rw.WriteHeader(http.StatusOK)
				rw.Write([]byte(ip))
			})
		}
	}
	return nil
}

// route browser
func (p *Captain) routeIcon() error {
	http.HandleFunc("/favicon.ico", func(rw http.ResponseWriter, r *http.Request) {
		rw.Write([]byte("Hello, World!"))
	})
	return nil
}

func (p *Captain) route404() error {
	http.HandleFunc("/", func(rw http.ResponseWriter, r *http.Request) {
		clientIP, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			rw.WriteHeader(http.StatusInternalServerError)
			rw.Write([]byte(err.Error()))
			return
		}

		p.mu.Lock()
		if p.Suspects[clientIP] == nil {
			p.Suspects[clientIP] = &Suspect{Time: time.Now(), Count: 1}
		} else {
			p.Suspects[clientIP].Count++
		}
		shouldBan := p.Suspects[clientIP].Count >= 5
		p.mu.Unlock()

		if shouldBan {
			if err := p.banIP(clientIP); err != nil {
				rw.WriteHeader(http.StatusInternalServerError)
				rw.Write([]byte(err.Error()))
				return
			}
		}
		rw.Write([]byte("Hello, World!"))
	})
	return nil
}

func (p *Captain) watchSuspects() {
	ticker := time.NewTicker(10 * time.Minute)
	go func() {
		for {
			select {
			case <-ticker.C:
				if err := p.freeSuspects(); err != nil {
					os.Exit(1)
				}
			}
		}
	}()
}

func (p *Captain) freeSuspects() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	for k, v := range p.Suspects {
		if !time.Now().After(v.Time.Add(time.Hour)) {
			continue
		}
		if v.Count >= 5 {
			if err := p.unbanIP(k); err != nil {
				return err
			}
		}
		delete(p.Suspects, k)
	}
	return nil
}

func (p *Captain) Run() error {
	if err := p.loadConfig(); err != nil {
		log.Panic(err)
	}
	p.Suspects = make(map[string]*Suspect)
	if err := p.ensureBaseRules(); err != nil {
		log.Panic(err)
	}
	p.route404()
	p.routeIcon()
	p.routes()
	p.watchSuspects()
	log.Fatal(http.ListenAndServe("0.0.0.0:"+p.HTTPort, nil))
	return nil
}

func iptables(args ...string) error {
	c := exec.Command("sudo", append([]string{"iptables"}, args...)...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}

func iptablesHas(spec ...string) bool {
	c := exec.Command("sudo", append([]string{"iptables", "-C", "INPUT"}, spec...)...)
	return c.Run() == nil
}

func iptablesInsert(spec ...string) error {
	if iptablesHas(spec...) {
		return nil
	}
	return iptables(append([]string{"-I", "INPUT"}, spec...)...)
}

func iptablesDelete(spec ...string) error {
	if !iptablesHas(spec...) {
		return nil
	}
	return iptables(append([]string{"-D", "INPUT"}, spec...)...)
}

func (p *Captain) loadConfig() error {
	data, err := os.ReadFile("/etc/port-guardian/guardian.json")
	if err != nil {
		log.Panic(err)
	}
	if err := json.Unmarshal(data, &p); err != nil {
		return err
	}
	for i := range p.Ports {
		proto, err := normalizeProtocol(p.Ports[i].Protocol)
		if err != nil {
			return fmt.Errorf("port %s: %w", p.Ports[i].Port, err)
		}
		p.Ports[i].Protocol = proto
	}
	return nil
}
EOF
}

build() {
	local work=$1 go_bin goarch version
	write_sources "$work/src"
	if command -v go >/dev/null 2>&1; then
		go_bin=$(command -v go)
	else
		case $(uname -m) in
		x86_64 | amd64) goarch=amd64 ;;
		aarch64 | arm64) goarch=arm64 ;;
		armv7l | armv6l) goarch=armv6l ;;
		i386 | i686) goarch=386 ;;
		*) die "unsupported architecture $(uname -m)" ;;
		esac
		version=${GO_VERSION:-$(curl -fsSL "$GO_MIRROR/VERSION?m=text" | head -n1)}
		[[ $version == go* ]] || die "could not look up the Go version from $GO_MIRROR"
		info "downloading $version for linux-$goarch"
		curl -fsSL "$GO_MIRROR/dl/$version.linux-$goarch.tar.gz" | tar -C "$work" -xz
		go_bin=$work/go/bin/go
	fi
	info "building port-guardian"
	(
		cd "$work/src"
		GOPATH=$work/gopath GOCACHE=$work/cache GOTOOLCHAIN=local CGO_ENABLED=0 \
			"$go_bin" build -trimpath -ldflags='-s -w' -o "$work/port-guardian" .
	)
}

write_config() {
	local item port proto first=1
	local -a items
	IFS=, read -ra items <<<"$PORTS"
	mkdir -p "$CONF_DIR"
	chmod 700 "$CONF_DIR"
	{
		printf '{\n  "httpPort": "%s",\n  "ports": [' "$HTTP_PORT"
		for item in "${items[@]}"; do
			port=${item%%/*}
			proto=${item#*/}
			[[ $proto == "$item" ]] && proto=tcp
			[[ $first -eq 1 ]] || printf ','
			first=0
			printf '\n    {"port": "%s", "protocol": "%s", "passports": [{"path": "%s", "name": "%s", "ip": ""}]}' \
				"$port" "$proto" "$PASS_PATH" "$PASSPORT_NAME"
		done
		printf '\n  ]\n}\n'
	} >"$CONF_FILE"
	printf 'HTTP_PORT=%s\nPORTS=%s\nPASS_PATH=%s\n' "$HTTP_PORT" "$PORTS" "$PASS_PATH" >"$STATE_FILE"
	chmod 600 "$CONF_FILE" "$STATE_FILE"
}

start_service() {
	if has_systemd; then
		cat >"$UNIT" <<EOF
[Unit]
Description=Port Guardian (IP whitelist for proxy ports)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
		systemctl daemon-reload
		systemctl enable port-guardian.service >/dev/null 2>&1
		systemctl restart port-guardian.service
	else
		info "systemd not found; starting in the background (it will not survive a reboot)"
		nohup "$BIN" >/var/log/port-guardian.log 2>&1 &
	fi
	local _
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if curl -fsS --max-time 1 "http://127.0.0.1:$HTTP_PORT/favicon.ico" >/dev/null 2>&1; then
			return
		fi
		sleep 1
	done
	die "port-guardian did not start; check: journalctl -u port-guardian -n 50 (or /var/log/port-guardian.log)"
}

install() {
	local force=$1 item port
	local -a items seen=()
	load_state
	PORTS=${PORTS_ARG:-$OLD_PORTS}
	HTTP_PORT=${HTTP_PORT_ARG:-${OLD_HTTP_PORT:-$((RANDOM % 40000 + 20000))}}
	PASS_PATH=${PATH_ARG:-${OLD_PASS_PATH:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}}

	[[ -n $PORTS ]] || die "--ports is required on first install, e.g. --ports 443/tcp,8443/udp"
	[[ $HTTP_PORT =~ ^[0-9]+$ && $HTTP_PORT -ge 1 && $HTTP_PORT -le 65535 ]] || die "invalid --http-port $HTTP_PORT"
	[[ $PASS_PATH =~ ^[A-Za-z0-9_-]{8,}$ ]] || die "--path must be 8+ letters, digits, '-' or '_'"
	IFS=, read -ra items <<<"$PORTS"
	for item in "${items[@]}"; do
		[[ $item =~ ^([0-9]+)(/(tcp|udp))?$ ]] || die "invalid port '$item', want PORT, PORT/tcp or PORT/udp"
		port=${BASH_REMATCH[1]}
		[[ $port -ge 1 && $port -le 65535 ]] || die "invalid port $port"
		[[ $port != "$HTTP_PORT" ]] || die "--http-port $HTTP_PORT is also in --ports"
		[[ " ${seen[*]} " != *" $port "* ]] || die "port $port is listed twice; tcp and udp cannot share one port number"
		seen+=("$port")
		if [[ $force -eq 0 ]] && sshd_ports | grep -qx "$port"; then
			die "sshd listens on $port; guarding it would lock you out (use --force to insist)"
		fi
	done

	install_deps
	WORK=$(mktemp -d)
	trap 'rm -rf "$WORK"' EXIT
	build "$WORK"

	stop_service
	if [[ -n $OLD_PORTS ]]; then
		info "removing the previous iptables rules"
		cleanup_rules "$OLD_PORTS" "$OLD_HTTP_PORT"
	fi
	command install -m 755 "$WORK/port-guardian" "$BIN"
	write_config
	firewall_allow "$HTTP_PORT"
	start_service
	info "port-guardian is running"
	show
	cat <<EOF

Remember to allow TCP $HTTP_PORT in your cloud provider's security group, if it has one.
EOF
}

sshd_ports() {
	echo 22
	if command -v ss >/dev/null 2>&1; then
		ss -ltnpH 2>/dev/null | awk '/sshd/ {n = split($4, a, ":"); print a[n]}'
	fi
}

main() {
	local action=install force=0
	PORTS_ARG='' HTTP_PORT_ARG='' PATH_ARG=''
	while [[ $# -gt 0 ]]; do
		case $1 in
		--ports) PORTS_ARG=${2:?--ports needs a value}; shift 2 ;;
		--http-port) HTTP_PORT_ARG=${2:?--http-port needs a value}; shift 2 ;;
		--path) PATH_ARG=${2:?--path needs a value}; shift 2 ;;
		--force) force=1; shift ;;
		--show) action=show; shift ;;
		--uninstall) action=uninstall; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option $1" ;;
		esac
	done
	[[ $(uname -s) == Linux ]] || die "port-guardian only runs on Linux"
	[[ $EUID -eq 0 ]] || die "please run as root (sudo bash install.sh ...)"
	case $action in
	install) install "$force" ;;
	show) show ;;
	uninstall) uninstall ;;
	esac
}

main "$@"
