#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Momory - IA Local — Dashboard + Admin unifié — port 7842"""
import hashlib,http.server,json,os,re,secrets,signal,socket,sqlite3,subprocess,threading,time,urllib.request
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT=int(os.environ.get("DASHBOARD_PORT",7842))
BIND=os.environ.get("DASHBOARD_BIND","0.0.0.0")   # Toutes interfaces (LAN + localhost)
CFG_FILE="/var/lib/ia-installer/config.env"
CREDS_FILE="/var/lib/ia-installer/admin-credentials"
PROGRESS_FILE="/var/lib/ia-installer/progress.json"
PENDING_CONFIRM_FILE="/var/lib/ia-installer/pending-confirm.json"
CONFIRM_ANSWER_FILE="/var/lib/ia-installer/confirm-answer.json"
NOTES_FILE="/var/lib/ia-installer/dashboard-notes.json"
INSTALL_PID_FILE="/var/lib/ia-installer/web-install.pid"
SESSION_TTL=86400   # 24h par défaut — modifiable via ADMIN_SESSION_TTL dans config.env
# Lire la durée de session depuis la config si définie
try:
    import re as _re2; _m=_re2.search(r"ADMIN_SESSION_TTL\s*=\s*(\d+)",open(CFG_FILE).read())
    if _m: SESSION_TTL=max(300,min(int(_m.group(1)),604800))  # Clamp: 5min–7jours
except: pass

# ── Config ───────────────────────────────────────────────────────────────────
def _cfg():
    """Lit $IA_CONFIG_FILE, écrit par save_config (bash) au format
    CFG[cle]=valeur ; %q échappe la valeur à la façon shell (guillemets,
    $'...'), donc on la dé-échappe via shlex plutôt qu'un simple strip.
    """
    import re as _re3, shlex as _shlex
    c={}
    try:
        for l in Path(CFG_FILE).read_text().splitlines():
            l=l.strip()
            if not l or l.startswith("#"): continue
            m=_re3.match(r'^CFG\[([^\]]+)\]=(.*)$', l)
            if not m: continue
            key=m.group(1)
            try:
                parts=_shlex.split(m.group(2))
                c[key]=parts[0] if parts else ""
            except ValueError:
                c[key]=m.group(2).strip('"')
    except: pass
    return c

def _run(cmd,t=3):
    try: return subprocess.run(cmd,shell=True,capture_output=True,text=True,timeout=t).stdout.strip()
    except: return ""

def _runx(cmd,t=15):
    try:
        r=subprocess.run(cmd,shell=True,capture_output=True,text=True,timeout=t)
        return {"ok":r.returncode==0,"out":r.stdout.strip(),"err":r.stderr.strip()}
    except Exception as e: return {"ok":False,"out":"","err":str(e)}

def _r(p,d="0"):
    try: return Path(p).read_text().strip()
    except: return d

# ── Auth ─────────────────────────────────────────────────────────────────────
def _load_creds():
    DEFAULT_HASH=hashlib.sha256(b"ia-local-admin").hexdigest()
    try:
        d=json.loads(Path(CREDS_FILE).read_text())
        if "user" in d and "hash" in d:
            d["is_default"]=(d["hash"]==DEFAULT_HASH)
            return d
    except: pass
    c={"user":"admin","hash":DEFAULT_HASH,"is_default":True}
    try: Path(CREDS_FILE).write_text(json.dumps({"user":"admin","hash":DEFAULT_HASH})); Path(CREDS_FILE).chmod(0o600)
    except: pass
    return c

def _check_pw(user,pw):
    c=_load_creds()
    return c["user"]==user and c["hash"]==hashlib.sha256(pw.encode()).hexdigest()

def _save_creds(user,pw):
    h=hashlib.sha256(pw.encode()).hexdigest()
    d={"user":user,"hash":h}
    Path(CREDS_FILE).write_text(json.dumps(d)); Path(CREDS_FILE).chmod(0o600)

_sess={}; _sl=threading.Lock()

# ── Rate limiting login (anti brute-force) ────────────────────────────────────
# Max 5 tentatives par IP sur 5 minutes — blocage 15 minutes après dépassement
_rl={}; _rl_lock=threading.Lock()
RL_MAX=5; RL_WINDOW=300; RL_BLOCK=900   # 5 essais / 5min → bloqué 15min

def _rl_check(ip):
    """Retourne (autorisé:bool, secondes_restantes:int)"""
    now=time.time()
    with _rl_lock:
        r=_rl.get(ip,{"tries":[],"blocked_until":0})
        if r["blocked_until"] > now:
            return False, int(r["blocked_until"]-now)
        # Nettoyer les tentatives hors fenêtre
        r["tries"]=[t for t in r["tries"] if now-t < RL_WINDOW]
        if len(r["tries"]) >= RL_MAX:
            r["blocked_until"]=now+RL_BLOCK
            _rl[ip]=r
            return False, RL_BLOCK
        return True, 0

def _rl_record(ip):
    now=time.time()
    with _rl_lock:
        r=_rl.get(ip,{"tries":[],"blocked_until":0})
        r["tries"].append(now)
        _rl[ip]=r

def _rl_reset(ip):
    with _rl_lock:
        _rl.pop(ip,None)

def _new_sess():
    tok=secrets.token_hex(32)
    with _sl: _sess[tok]=time.time()
    return tok

def _valid_sess(tok):
    if not tok: return False
    with _sl:
        ts=_sess.get(tok,0)
        if time.time()-ts<SESSION_TTL:
            _sess[tok]=time.time(); return True
        _sess.pop(tok,None)
    return False

def _del_sess(tok):
    with _sl: _sess.pop(tok,None)

def _get_tok(hdrs):
    for p in hdrs.get("Cookie","").split(";"):
        k,_,v=p.strip().partition("=")
        if k.strip()=="ia_sess": return v.strip()
    return ""

# ── Collecte stats ────────────────────────────────────────────────────────────
_cp={}
def get_cpu():
    res={"pct":0,"freq_mhz":0,"temp_c":None,"cores":[],"model":""}
    try:
        stats={}
        for l in Path("/proc/stat").read_text().splitlines():
            if l.startswith("cpu"):
                p=l.split();n=p[0];v=list(map(int,p[1:8]))
                stats[n]=(sum(v),v[3]+v[4])
        global _cp
        if _cp:
            for n,(tot,idl) in stats.items():
                pt,pi=_cp.get(n,(tot,idl));dt=tot-pt;di=idl-pi
                pc=round((dt-di)*100/dt,1) if dt>0 else 0.
                if n=="cpu": res["pct"]=pc
                else: res["cores"].append({"name":n,"pct":pc})
        _cp=stats
        f=_r("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
        if f and f!="0": res["freq_mhz"]=round(int(f)/1000)
        else:
            m=re.search(r"cpu MHz\s*:\s*([\d.]+)",_r("/proc/cpuinfo",""))
            if m: res["freq_mhz"]=round(float(m.group(1)))
        for z in sorted(Path("/sys/class/thermal").glob("thermal_zone*/temp")):
            try:
                t=int(z.read_text().strip())/1000
                if t>0: res["temp_c"]=round(t,1); break
            except: pass
        for l in Path("/proc/cpuinfo").read_text().splitlines():
            if l.startswith("model name"): res["model"]=l.split(":",1)[1].strip(); break
    except: pass
    return res

def get_mem():
    res={"ram_total_mb":0,"ram_used_mb":0,"ram_pct":0,"swap_total_mb":0,"swap_used_mb":0,"swap_pct":0}
    try:
        mi={}
        for l in Path("/proc/meminfo").read_text().splitlines():
            k,_,v=l.partition(":"); mi[k.strip()]=int(v.split()[0]) if v.strip() else 0
        tot=mi.get("MemTotal",0);av=mi.get("MemAvailable",0);u=tot-av
        res["ram_total_mb"]=round(tot/1024);res["ram_used_mb"]=round(u/1024)
        res["ram_pct"]=round(u*100/tot,1) if tot else 0
        st=mi.get("SwapTotal",0);sf=mi.get("SwapFree",0);su=st-sf
        res["swap_total_mb"]=round(st/1024);res["swap_used_mb"]=round(su/1024)
        res["swap_pct"]=round(su*100/st,1) if st else 0
    except: pass
    return res

def get_gpu():
    res={"available":False,"brand":"none"}
    try:
        out=_run("nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,power.limit --format=csv,noheader,nounits",t=4)
        if out:
            p=[x.strip() for x in out.split(",")]
            tot=int(p[4]) if len(p)>4 else 1
            res.update({"available":True,"brand":"nvidia","name":p[0] if p else "NVIDIA",
                "util_pct":float(p[1]) if len(p)>1 else 0,"temp_c":float(p[2]) if len(p)>2 else 0,
                "mem_used_mb":int(p[3]) if len(p)>3 else 0,"mem_total_mb":tot,
                "mem_pct":round(int(p[3])*100/tot,1) if len(p)>3 else 0,
                "power_w":float(p[5]) if len(p)>5 else 0,"power_limit_w":float(p[6]) if len(p)>6 else 0})
            return res
    except: pass
    try:
        out=_run("rocm-smi --showuse 2>/dev/null",t=4)
        if out and "GPU" in out:
            u=re.search(r"(\d+)%",out)
            res.update({"available":True,"brand":"amd","name":"AMD GPU","util_pct":int(u.group(1)) if u else 0})
    except: pass
    return res

# ═══════════════════════════════════════════════════════════════
#  CONSOMMATION ÉLECTRIQUE — estimation logicielle + historique
#  CPU (RAPL) et GPU NVIDIA (nvidia-smi) sont des mesures réelles du
#  capteur matériel. Disques/RAM/overhead sont des estimations basées
#  sur des valeurs typiques (pas de capteur disponible pour ces
#  composants sur du matériel grand public).
# ═══════════════════════════════════════════════════════════════
POWER_DB_FILE = "/var/lib/ia-installer/power_history.db"
_rapl_prev = None   # (energie_uj, timestamp) — pour calculer la puissance par delta

RAM_W_PER_GB = 0.3          # DDR3/DDR4, valeur usuelle
BASE_OVERHEAD_W = 25.0      # carte mère, ventilateurs, alim — forfait
DISK_HDD_ACTIVE_W = 7.0
DISK_HDD_IDLE_W = 5.0
DISK_SSD_ACTIVE_W = 3.5
DISK_SSD_IDLE_W = 0.8
DISK_IO_ACTIVE_THRESHOLD_KBS = 200   # au-delà, le disque est considéré "actif"

def _rapl_power_w():
    """Puissance CPU réelle via RAPL (Intel/AMD). None si indisponible."""
    path = "/sys/class/powercap/intel-rapl:0/energy_uj"
    try:
        energy_uj = int(Path(path).read_text().strip())
    except Exception:
        return None
    global _rapl_prev
    now = time.time()
    if _rapl_prev is None:
        _rapl_prev = (energy_uj, now)
        return None   # premier échantillon, pas encore de delta possible
    prev_uj, prev_t = _rapl_prev
    dt = now - prev_t
    if dt <= 0:
        return None
    # Le compteur RAPL boucle (wraps) périodiquement ; si la valeur a
    # diminué, on ignore cet échantillon plutôt que de calculer un delta négatif.
    if energy_uj < prev_uj:
        _rapl_prev = (energy_uj, now)
        return None
    watts = (energy_uj - prev_uj) / 1_000_000 / dt
    _rapl_prev = (energy_uj, now)
    return round(watts, 1)

def _disk_type_and_activity(device_path, read_kb_s, write_kb_s):
    """Retourne (est_hdd, est_actif) pour un chemin de device (ex: /dev/sda1)."""
    # /dev/sda1 -> sda (le sysfs rotational est au niveau du disque, pas de la partition)
    dev = device_path.replace("/dev/", "")
    dev = re.sub(r'\d+$', '', dev) if not dev.startswith(("nvme", "mmcblk")) else re.sub(r'p?\d+$', '', dev)
    is_hdd = True
    try:
        rot = _r(f"/sys/block/{dev}/queue/rotational", "1")
        is_hdd = rot.strip() == "1"
    except Exception:
        pass
    active = (read_kb_s + write_kb_s) > DISK_IO_ACTIVE_THRESHOLD_KBS
    return is_hdd, active

def estimate_power(cpu_data, gpu_data, mem_data, disks_data):
    """Calcule la ventilation de puissance actuelle. Chaque champ *_real
    indique si la valeur vient d'un capteur matériel (True) ou d'une
    estimation logicielle (False)."""
    cpu_w = _rapl_power_w()
    cpu_real = cpu_w is not None
    if cpu_w is None:
        # Repli grossier : ~2.5W/coeur au repos jusqu'à ~9W/coeur en pleine charge.
        n_cores = max(len(cpu_data.get("cores", [])), 1)
        pct = cpu_data.get("pct", 0) / 100
        cpu_w = round(n_cores * (2.5 + pct * 6.5), 1)

    gpu_w = gpu_data.get("power_w") if gpu_data.get("available") else 0
    gpu_real = gpu_data.get("available", False) and gpu_data.get("power_w") is not None
    gpu_w = gpu_w or 0

    disk_w = 0.0
    for d in disks_data:
        is_hdd, active = _disk_type_and_activity(
            d.get("device", ""), d.get("read_kb_s", 0), d.get("write_kb_s", 0)
        )
        if is_hdd:
            disk_w += DISK_HDD_ACTIVE_W if active else DISK_HDD_IDLE_W
        else:
            disk_w += DISK_SSD_ACTIVE_W if active else DISK_SSD_IDLE_W

    ram_gb = mem_data.get("ram_total_mb", 0) / 1024
    ram_w = round(ram_gb * RAM_W_PER_GB, 1)

    total = round(cpu_w + gpu_w + disk_w + ram_w + BASE_OVERHEAD_W, 1)

    return {
        "cpu_w": cpu_w, "cpu_real": cpu_real,
        "gpu_w": round(gpu_w, 1), "gpu_real": gpu_real,
        "disk_w": round(disk_w, 1), "disk_real": False,
        "ram_w": ram_w, "ram_real": False,
        "base_w": BASE_OVERHEAD_W, "base_real": False,
        "total_w": total,
    }

def _power_db():
    conn = sqlite3.connect(POWER_DB_FILE)
    conn.execute("""CREATE TABLE IF NOT EXISTS power_samples (
        ts REAL PRIMARY KEY, cpu_w REAL, gpu_w REAL, disk_w REAL, ram_w REAL, total_w REAL
    )""")
    return conn

def _power_settings():
    """Réglages énergie stockés dans le même config.env que le reste (CFG)."""
    cfg = _cfg()
    return {
        "kwh_price": float(cfg.get("kwh_price", "0.2016")),   # tarif réglementé FR approximatif par défaut
        "provider": cfg.get("kwh_provider", ""),
        "retention_days": int(cfg.get("power_retention_days", "90")),
    }

def save_power_settings(kwh_price, provider, retention_days):
    Path("/var/lib/ia-installer").mkdir(parents=True, exist_ok=True)
    lines = []
    if Path(CFG_FILE).exists():
        for l in Path(CFG_FILE).read_text().splitlines():
            if not re.match(r'^CFG\[(kwh_price|kwh_provider|power_retention_days)\]=', l):
                lines.append(l)
    lines.append(f'CFG[kwh_price]={kwh_price!r}')
    lines.append(f'CFG[kwh_provider]={provider!r}')
    lines.append(f'CFG[power_retention_days]={retention_days!r}')
    Path(CFG_FILE).parent.mkdir(parents=True, exist_ok=True)
    Path(CFG_FILE).write_text("\n".join(lines) + "\n")

def power_monitor_loop():
    """Thread de fond : calcule la puissance toutes les 10s (cache pour l'API
    live), et persiste un échantillon en base toutes les 60s pour l'historique."""
    global _LATEST_POWER
    tick = 0
    while True:
        try:
            cpu_data = get_cpu()
            gpu_data = get_gpu()
            mem_data = get_mem()
            disks_data = get_disks()
            power = estimate_power(cpu_data, gpu_data, mem_data, disks_data)
            power["error"] = None
            _LATEST_POWER = power

            if tick % 6 == 0:   # ~60s (10s * 6)
                try:
                    conn = _power_db()
                    conn.execute(
                        "INSERT OR REPLACE INTO power_samples (ts,cpu_w,gpu_w,disk_w,ram_w,total_w) VALUES (?,?,?,?,?,?)",
                        (time.time(), power["cpu_w"], power["gpu_w"], power["disk_w"], power["ram_w"], power["total_w"])
                    )
                    retention = _power_settings()["retention_days"]
                    cutoff = time.time() - retention * 86400
                    conn.execute("DELETE FROM power_samples WHERE ts < ?", (cutoff,))
                    conn.commit()
                    conn.close()
                except Exception as e:
                    pass
        except Exception as e:
            import traceback
            _LATEST_POWER = {**_LATEST_POWER, "error": f"{type(e).__name__}: {e}",
                              "error_trace": traceback.format_exc(limit=3)}
        tick += 1
        time.sleep(10)

_LATEST_POWER = {"cpu_w":0,"cpu_real":False,"gpu_w":0,"gpu_real":False,"disk_w":0,"disk_real":False,
                  "ram_w":0,"ram_real":False,"base_w":BASE_OVERHEAD_W,"base_real":False,"total_w":0,
                  "error":"pas encore échantillonné"}

def get_power_history(period):
    """period : '24h' | '7d' | '30d'. Renvoie une série agrégée adaptée à la
    période pour ne pas surcharger le graphique de points."""
    now = time.time()
    windows = {
        "24h": (86400, 300),        # 24h de recul, bin de 5 min
        "7d":  (7*86400, 3600),     # 7 jours, bin de 1h
        "30d": (30*86400, 4*3600),  # 30 jours, bin de 4h
    }
    lookback, bin_size = windows.get(period, windows["24h"])
    cutoff = now - lookback
    try:
        conn = _power_db()
        rows = conn.execute(
            "SELECT ts,total_w,cpu_w,gpu_w,disk_w,ram_w FROM power_samples WHERE ts >= ? ORDER BY ts",
            (cutoff,)
        ).fetchall()
        conn.close()
    except Exception:
        rows = []

    if not rows:
        return {"points": [], "avg_w": 0, "kwh_period": 0}

    # Agrégation par bin (moyenne)
    bins = {}
    for ts, total_w, cpu_w, gpu_w, disk_w, ram_w in rows:
        b = int(ts // bin_size)
        bins.setdefault(b, []).append((ts, total_w, cpu_w, gpu_w, disk_w, ram_w))

    points = []
    for b in sorted(bins):
        vals = bins[b]
        n = len(vals)
        points.append({
            "ts": sum(v[0] for v in vals) / n,
            "total_w": round(sum(v[1] for v in vals) / n, 1),
            "cpu_w": round(sum(v[2] for v in vals) / n, 1),
            "gpu_w": round(sum(v[3] for v in vals) / n, 1),
            "disk_w": round(sum(v[4] for v in vals) / n, 1),
            "ram_w": round(sum(v[5] for v in vals) / n, 1),
        })

    avg_w = sum(p["total_w"] for p in points) / len(points)
    # kWh consommés sur la période = puissance moyenne (kW) × durée réelle couverte (h)
    duration_h = (rows[-1][0] - rows[0][0]) / 3600 if len(rows) > 1 else 0
    kwh_period = round(avg_w / 1000 * duration_h, 3)

    return {"points": points, "avg_w": round(avg_w, 1), "kwh_period": kwh_period}

_dp={}
def get_disks():
    disks=[]
    try:
        out=_run("df -BM --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2")
        for l in out.splitlines():
            p=l.split()
            if len(p)<6: continue
            src=p[0]
            if any(x in src for x in ("tmpfs","devtmpfs","udev","loop","overlay","none")): continue
            pct=int(p[4].replace("%","")) if p[4].replace("%","").isdigit() else 0
            dev=src.replace("/dev/","").split("/")[-1]; io={}
            try:
                sl2=_run(f"grep ' {dev} ' /proc/diskstats 2>/dev/null | head -1")
                if sl2:
                    sp=sl2.split()
                    if len(sp)>=14:
                        rd=int(sp[5]);wr=int(sp[9]);now=time.time()
                        prev=_dp.get(dev)
                        if prev:
                            dt=now-prev[2]
                            if dt>0:
                                io["read_kb_s"]=round((rd-prev[0])*512/1024/dt)
                                io["write_kb_s"]=round((wr-prev[1])*512/1024/dt)
                        _dp[dev]=(rd,wr,now)
            except: pass
            disks.append({"device":src,"size_mb":int(p[1].replace("M","")),
                          "used_mb":int(p[2].replace("M","")),"avail_mb":int(p[3].replace("M","")),
                          "pct":pct,"mount":p[5],**io})
    except: pass
    return disks

_np={}
def get_net():
    res={"interfaces":[],"default_iface":"","local_ip":""}
    try:
        df=_run("ip route 2>/dev/null | awk '/^default/{print $5;exit}'")
        res["default_iface"]=df
        if df:
            m=re.search(r"inet ([\d.]+)",_run(f"ip -4 addr show {df} 2>/dev/null"))
            if m: res["local_ip"]=m.group(1)
        global _np; now=time.time()
        for l in Path("/proc/net/dev").read_text().splitlines()[2:]:
            p=l.split()
            if len(p)<10: continue
            n=p[0].rstrip(":")
            if n=="lo": continue
            rx=int(p[1]);tx=int(p[9])
            prev=_np.get(n); dt=now-_np.get("__ts__",now)
            rxr=round((rx-prev[0])/1024/max(dt,.1)) if prev else 0
            txr=round((tx-prev[1])/1024/max(dt,.1)) if prev else 0
            _np[n]=(rx,tx)
            res["interfaces"].append({"name":n,"rx_kb_s":max(0,rxr),"tx_kb_s":max(0,txr),
                "rx_total_mb":round(rx/1024/1024,1),"tx_total_mb":round(tx/1024/1024,1)})
        _np["__ts__"]=now
    except: pass
    return res

def get_lan_ip():
    """IP LAN réelle de la machine (pas 127.0.0.1) — pour qu'un client distant
    (ex: Momory CLI sur un autre PC) sache à quelle adresse se connecter."""
    try:
        s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        ip=s.getsockname()[0]
        s.close()
        return ip
    except:
        return socket.gethostbyname(socket.gethostname())

def get_momory_info(ollama_models):
    """Valeurs prêtes à coller dans `momory config --setup` sur une autre machine."""
    cfg=_cfg()
    chat=next((m for m in ollama_models if any(k in m.lower() for k in ("llama","mistral","gemma"))), None)
    coder=next((m for m in ollama_models if "code" in m.lower()), None)
    info={
        "host": get_lan_ip(),
        "port": 11434,
        "chat_model": chat or (ollama_models[0] if ollama_models else None),
        "coder_model": coder or chat or (ollama_models[0] if ollama_models else None),
    }
    if cfg.get("qdrant_port"):
        info["qdrant_port"] = cfg.get("qdrant_port")
    return info

def get_svc():
    cfg=_cfg()
    wp=cfg.get("webui_port","8080"); oh=cfg.get("ollama_host","127.0.0.1")
    if oh=="0.0.0.0": oh="127.0.0.1"
    res={"ollama":{"active":False,"url":f"http://{oh}:11434","models":[],"model_count":0},
         "webui":{"active":False,"url":f"http://localhost:{wp}"},
         "docker":{"active":False,"containers":0}}
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags",timeout=1) as r:
            d=json.loads(r.read()); ms=[m["name"] for m in d.get("models",[])]
            res["ollama"].update({"active":True,"models":ms,"model_count":len(ms)})
    except: pass
    try:
        ps=_run("docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null",t=2); c=0
        for l in ps.splitlines():
            if not l.strip(): continue
            c+=1; nm,_,st=l.partition("|")
            if nm.strip()=="open-webui": res["webui"].update({"active":"Up" in st,"status":st.strip()})
        res["docker"].update({"active":True,"containers":c})
    except: pass
    return res

def get_up():
    try:
        s=float(_r("/proc/uptime").split()[0])
        d,h,m,sc=int(s//86400),int((s%86400)//3600),int((s%3600)//60),int(s%60)
        return {"seconds":int(s),"human":f"{d}j {h:02d}h{m:02d}m" if d else f"{h:02d}h{m:02d}m{sc:02d}s"}
    except: return {"seconds":0,"human":"?"}

def get_progress():
    """Lit le fichier progress.json écrit par le script bash pendant l'installation."""
    try:
        d=json.loads(Path(PROGRESS_FILE).read_text())
        if isinstance(d,dict) and d.get("active"): return d
    except: pass
    return None   # Pas d'installation en cours

def get_pending_confirm():
    """Lit une éventuelle question confirm() en attente de réponse (terminal OU web)."""
    try:
        d=json.loads(Path(PENDING_CONFIRM_FILE).read_text())
        if isinstance(d,dict) and d.get("pending"): return d
    except: pass
    return None

def collect():
    pg=get_progress()
    svc=get_svc()
    return {"ts":time.time(),"cpu":get_cpu(),"memory":get_mem(),"gpu":get_gpu(),
            "disks":get_disks(),"network":get_net(),"services":svc,
            "uptime":get_up(),"hostname":socket.gethostname(),
            "progress":pg,             # Utilisé par la bannière de progression JS
            "install_progress":pg,     # Rétrocompatibilité
            "pending_confirm":get_pending_confirm(),
            "power":_LATEST_POWER,
            "momory":get_momory_info(svc.get("ollama",{}).get("models",[]))}

_cache={}; _lock=threading.Lock()
def _worker():
    # 1er collect initialise _cp sans delta — on attend 1s pour un vrai delta CPU
    try: collect()
    except: pass
    time.sleep(1)
    while True:
        try:
            with _lock: globals()["_cache"]=collect()
        except: pass
        time.sleep(2)

# ── API Admin ─────────────────────────────────────────────────────────────────
def api_admin_status():
    creds=_load_creds()
    cfg=_cfg(); wp=cfg.get("webui_port","8080"); oh=cfg.get("ollama_host","127.0.0.1")
    if oh=="0.0.0.0": oh="127.0.0.1"
    def svc_on(n): return _runx(f"systemctl is-active --quiet {n}",t=3)["ok"]
    def ctr_on(n): return n in _run(f"docker ps --filter name=^{n}$ --format '{{{{.Names}}}}' 2>/dev/null",t=3)
    models=[]
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags",timeout=1) as r:
            models=[m["name"] for m in json.loads(r.read()).get("models",[])]
    except: pass
    return {
        "is_default_password":creds.get("is_default",False),
        "admin_user":creds.get("user","admin"),
        "services":{
            "ollama":{"active":svc_on("ollama"),"url":f"http://{oh}:11434",
                      "version":_run("ollama --version 2>/dev/null | grep -oP '[\\d.]+' | head -1",t=3) or "?"},
            "webui": {"active":ctr_on("open-webui"),"url":f"http://localhost:{wp}"},
            "docker":{"active":svc_on("docker")},
            "dashboard":{"active":svc_on("ia-dashboard"),"url":f"http://localhost:{PORT}"},
        },
        "models":models,
        "disk":_run("df -h / 2>/dev/null | tail -1 | awk '{print $3\"/\"$2\" (\"$5\")}' ",t=3) or "?",
        "hostname":socket.gethostname(),
        "uptime":_run("uptime -p 2>/dev/null",t=2) or "?",
    }

def api_svc_action(body):
    act=body.get("action",""); svc=body.get("service","")
    MAP={"ollama":("sys","ollama"),"docker":("sys","docker"),
         "dashboard":("sys","ia-dashboard"),"webui":("docker","open-webui")}
    if act not in {"start","stop","restart"} or svc not in MAP:
        return {"ok":False,"msg":"Paramètre invalide"}
    kind,name=MAP[svc]
    if kind=="sys":
        r=_runx(f"systemctl {act} {name}",t=30)
    else:
        cmds={"start":f"docker start {name}","stop":f"docker stop {name}",
              "restart":f"docker stop {name} && docker start {name}"}
        r=_runx(cmds[act],t=30)
    return {"ok":r["ok"],"msg":r["out"] or r["err"] or ("OK" if r["ok"] else "Erreur")}

def api_update(body):
    target=body.get("target","")
    # Whitelist des cibles autorisées
    if target not in {"ollama","webui","system"}:
        return {"ok":False,"msg":"Cible invalide"}
    if target=="ollama":
        # Téléchargement + vérification SHA256 avant exécution
        chk=_runx(
            "set -e; "
            "TMP=$(mktemp /tmp/ollama-XXXXXX.sh); "
            "curl -fsSL --max-time 120 -o $TMP https://ollama.com/install.sh; "
            "LOCAL=$(sha256sum $TMP | cut -d' ' -f1); "
            "REMOTE=$(curl -sf --max-time 15 "
            "'https://api.github.com/repos/ollama/ollama/contents/install.sh' "
            "| python3 -c \"import sys,json,base64,hashlib;d=json.load(sys.stdin);"
            "c=base64.b64decode(d[\'content\']).decode(\'utf-8\',errors=\'replace\');"
            "print(hashlib.sha256(c.encode(\'utf-8\')).hexdigest())\" 2>/dev/null || echo ''); "
            "if [ -n \"$REMOTE\" ] && [ \"$LOCAL\" != \"$REMOTE\" ]; then "
            "  echo INTEGRITY_FAIL:local=$LOCAL:remote=$REMOTE; rm -f $TMP; exit 1; fi; "
            "chmod 700 $TMP && sh $TMP; rm -f $TMP",
            t=360)
        if not chk['ok'] and 'INTEGRITY_FAIL' in chk.get('out',''):
            return {"ok":False,"msg":"⛔ Intégrité du script Ollama non vérifiée — MAJ annulée par sécurité.\n"+chk['out']}
        r=chk
        return {"ok":r["ok"],"msg":r["out"] or r["err"]}
    if target=="webui":
        cfg=_cfg(); img=cfg.get("gpu_docker_img","ghcr.io/open-webui/open-webui:main")
        # Valider le format de l'image Docker (évite injection de commandes)
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._/:-]{5,150}$",img):
            return {"ok":False,"msg":f"Format d'image Docker invalide : {img}"}
        r1=_runx(f"docker pull {img}",t=600)
        if not r1["ok"]: return {"ok":False,"msg":r1["err"]}
        dd=cfg.get("webui_dir","/opt/open-webui"); pp=cfg.get("webui_port","8080")
        nt=cfg.get("docker_network","host")
        _runx("docker stop open-webui 2>/dev/null",t=15)
        _runx("docker rm   open-webui 2>/dev/null",t=10)
        if nt=="host":
            # Note sécurité : OLLAMA_BASE_URL et PORT ne sont pas des secrets
            # (URL locale + port) — visible dans 'docker inspect' mais non sensible
            cmd=f"docker run -d --network=host -v {dd}:/app/backend/data -e OLLAMA_BASE_URL=http://127.0.0.1:11434 -e PORT={pp} --name open-webui --restart unless-stopped {img}"
        else:
            cmd=f"docker run -d -p {pp}:8080 --add-host=host.docker.internal:host-gateway -v {dd}:/app/backend/data -e OLLAMA_BASE_URL=http://127.0.0.1:11434 --name open-webui --restart unless-stopped {img}"
        r2=_runx(cmd,t=30)
        return {"ok":r2["ok"],"msg":(r1["out"]+"\n"+r2.get("out","")).strip()}
    if target=="system":
        if os.path.exists("/usr/bin/apt"):
            r=_runx("DEBIAN_FRONTEND=noninteractive apt update && apt upgrade -y",t=600)
        elif os.path.exists("/usr/bin/dnf"):
            r=_runx("dnf upgrade -y",t=600)
        elif os.path.exists("/usr/bin/pacman"):
            r=_runx("pacman -Syu --noconfirm",t=600)
        else: return {"ok":False,"msg":"Gestionnaire de paquets non reconnu"}
        return {"ok":r["ok"],"msg":r["out"] or r["err"]}
    return {"ok":False,"msg":"Cible inconnue"}

def api_models(body):
    act=body.get("action","list")
    if act=="list":
        try:
            with urllib.request.urlopen("http://127.0.0.1:11434/api/tags",timeout=3) as r:
                return {"ok":True,"models":json.loads(r.read()).get("models",[])}
        except Exception as e: return {"ok":False,"models":[],"msg":str(e)}
    if act=="pull":
        nm=body.get("name","").strip()
        if not nm or not re.match(r'^[\w./:+-]+$',nm): return {"ok":False,"msg":"Nom invalide"}
        subprocess.Popen(["ollama","pull",nm],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return {"ok":True,"msg":f"Téléchargement de {nm} lancé…"}
    if act=="delete":
        nm=body.get("name","").strip()
        if not nm or not re.match(r'^[\w./:+-]+$',nm): return {"ok":False,"msg":"Nom invalide"}
        r=_runx(f"ollama rm {nm}",t=30)
        return {"ok":r["ok"],"msg":r["out"] or r["err"] or "OK"}
    return {"ok":False,"msg":"Action inconnue"}

def api_logs(body):
    # Whitelist stricte source — aucune valeur arbitraire acceptée
    VALID_SRCS={"ollama","webui","docker","dashboard","syslog","kernel","install"}
    src=body.get("source","ollama")
    if src not in VALID_SRCS: src="ollama"
    # Nombre de lignes : entier strict entre 10 et 500
    try: n=max(10,min(int(str(body.get("lines",100)).strip()),500))
    except: n=100
    cmds={"install":f"tail -n {n} /var/log/ia-installer/web-install.log 2>/dev/null || echo 'Log non disponible'",
          "ollama":f"journalctl -u ollama -n {n} --no-pager 2>/dev/null",
          "webui": f"docker logs --tail {n} open-webui 2>&1",
          "docker":f"journalctl -u docker -n {n} --no-pager 2>/dev/null",
          "dashboard":f"journalctl -u ia-dashboard -n {n} --no-pager 2>/dev/null",
          "syslog":f"journalctl -n {n} --no-pager 2>/dev/null",
          "kernel":f"journalctl -k -n {n} --no-pager 2>/dev/null"}
    r=_runx(cmds[src],t=15)
    return {"ok":True,"lines":r["out"].splitlines()}

def api_system_action(body):
    """Reboot, shutdown, mise à jour système depuis le dashboard."""
    action=body.get("action","")
    if action not in {"reboot","shutdown","update_system"}:
        return {"ok":False,"msg":"Action inconnue"}
    try:
        if action=="reboot":
            import threading
            def _do(): import time; time.sleep(2); subprocess.run(["shutdown","-r","now"])
            threading.Thread(target=_do,daemon=True).start()
            return {"ok":True,"msg":"🔄 Redémarrage dans 2 secondes…"}
        elif action=="shutdown":
            import threading
            def _do(): import time; time.sleep(2); subprocess.run(["shutdown","-h","now"])
            threading.Thread(target=_do,daemon=True).start()
            return {"ok":True,"msg":"⏻ Arrêt dans 2 secondes…"}
        elif action=="update_system":
            import threading,shutil
            def _do():
                try:
                    if shutil.which("apt"):
                        subprocess.run(["apt","update","-y"],timeout=120,capture_output=True)
                        subprocess.run(["apt","upgrade","-y","--auto-remove"],timeout=300,capture_output=True)
                    elif shutil.which("dnf"):
                        subprocess.run(["dnf","upgrade","-y"],timeout=300,capture_output=True)
                    elif shutil.which("pacman"):
                        subprocess.run(["pacman","-Syu","--noconfirm"],timeout=300,capture_output=True)
                    elif shutil.which("zypper"):
                        subprocess.run(["zypper","update","-y"],timeout=300,capture_output=True)
                except: pass
            threading.Thread(target=_do,daemon=True).start()
            return {"ok":True,"msg":"📦 Mise à jour système lancée en arrière-plan…"}
    except Exception as e:
        return {"ok":False,"msg":str(e)}

def api_launch_install(body):
    """Lance le script installateur en arrière-plan depuis le dashboard web."""
    import os, glob, pwd

    def _find_script():
        # 1. Chemin sauvegardé par le script bash au démarrage
        try:
            p = Path("/var/lib/ia-installer/installer-path.txt").read_text().strip()
            if p and os.path.isfile(p): return p
        except: pass
        # 2. Chercher dans /home/*/  et /root/
        for p in (
            glob.glob("/home/*/install_ia_local.sh") +
            glob.glob("/root/install_ia_local.sh") +
            glob.glob("/home/*/*/install_ia_local.sh") +
            ["/usr/local/bin/install_ia_local.sh","/opt/install_ia_local.sh"]
        ):
            if os.path.isfile(p): return p
        # 3. find système (dernier recours)
        found = _run("find / -maxdepth 6 -name 'install_ia_local.sh' -not -path '*/proc/*' -not -path '*/sys/*' 2>/dev/null | head -1", t=3)
        if found and os.path.isfile(found): return found
        return None

    script = _find_script()

    # Si trouvé mais pas dans /home/$user/ → créer le lien symbolique
    if script:
        try:
            # Trouver le home du premier utilisateur non-root
            for entry in pwd.getpwall():
                if entry.pw_uid >= 1000 and os.path.isdir(entry.pw_dir):
                    canonical = os.path.join(entry.pw_dir, "install_ia_local.sh")
                    if script != canonical and not os.path.isfile(canonical):
                        try:
                            os.symlink(script, canonical)
                            os.chown(canonical, entry.pw_uid, entry.pw_gid)
                            Path("/var/lib/ia-installer/installer-path.txt").write_text(script)
                        except: pass
                    break
        except: pass

    if not script:
        return {"ok":False,"msg":"Script install_ia_local.sh introuvable.\n\nLancez d'abord depuis le terminal :\n  sudo bash install_ia_local.sh\nLe dashboard retiendra ensuite son emplacement."}
    # Vérifier qu'une installation n'est pas déjà en cours
    try:
        d2 = json.loads(Path(PROGRESS_FILE).read_text())
        if d2.get("active"):
            return {"ok":False,"msg":"Installation déjà en cours — suivez la progression ci-dessus."}
    except: pass
    # Préparer le log
    log_dir = "/var/log/ia-installer"
    log_file = log_dir + "/web-install.log"
    try: os.makedirs(log_dir, exist_ok=True)
    except: pass
    try:
        with open(log_file,"a") as lf:
            proc = subprocess.Popen(
                ["bash", script, "--web-install"],
                stdout=lf, stderr=lf,
                close_fds=True,
                start_new_session=True
            )
        # On stocke le PID (== PGID grâce à start_new_session=True) pour
        # pouvoir tuer tout le groupe de process depuis api_cancel_install.
        try: Path(INSTALL_PID_FILE).write_text(str(proc.pid))
        except: pass
        return {"ok":True,"msg":"✅ Installation lancée ! Suivez la progression dans l'onglet ci-dessus."}
    except Exception as e:
        return {"ok":False,"msg":f"Erreur lancement : {e}"}

def _load_notes():
    try:
        d = json.loads(Path(NOTES_FILE).read_text(encoding="utf-8"))
        if isinstance(d, dict) and "notes" in d:
            return d
    except Exception:
        pass
    return {"notes": []}

def _save_notes(data):
    Path(NOTES_FILE).parent.mkdir(parents=True, exist_ok=True)
    Path(NOTES_FILE).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    os.chmod(NOTES_FILE, 0o640)

def api_notes_action(body):
    """Une seule route pour toutes les opérations notes : create / update /
    delete (corbeille) / restore / empty_trash. Suppression = déplacement en
    corbeille, jamais perte immédiate — la corbeille se vide explicitement."""
    action = body.get("action", "")
    data = _load_notes()
    notes = data["notes"]

    if action == "create":
        text = (body.get("text") or "").strip()[:5000]
        if not text:
            return {"ok": False, "msg": "Note vide."}
        notes.append({
            "id": secrets.token_hex(6),
            "text": text,
            "created_at": time.time(),
            "deleted": False,
        })
    elif action == "update":
        nid = body.get("id"); text = (body.get("text") or "").strip()[:5000]
        for n in notes:
            if n["id"] == nid:
                n["text"] = text
                break
        else:
            return {"ok": False, "msg": "Note introuvable."}
    elif action == "delete":
        nid = body.get("id"); found = False
        for n in notes:
            if n["id"] == nid:
                n["deleted"] = True
                n["deleted_at"] = time.time()
                found = True
                break
        if not found:
            return {"ok": False, "msg": "Note introuvable."}
    elif action == "restore":
        nid = body.get("id"); found = False
        for n in notes:
            if n["id"] == nid:
                n["deleted"] = False
                n.pop("deleted_at", None)
                found = True
                break
        if not found:
            return {"ok": False, "msg": "Note introuvable."}
    elif action == "empty_trash":
        data["notes"] = [n for n in notes if not n.get("deleted")]
    else:
        return {"ok": False, "msg": f"Action inconnue : {action}"}

    _save_notes(data)
    return {"ok": True, **data}

def api_confirm_answer(body):
    """Répond depuis le dashboard à une question confirm() posée par le script bash
    (voir _write_pending_confirm / _check_confirm_answer dans lib/common.sh)."""
    qid = (body.get("qid") or "").strip()
    answer = (body.get("answer") or "").strip().lower()
    if not qid or answer not in ("oui", "non"):
        return {"ok": False, "msg": "Requête invalide (qid/answer manquant)."}
    try:
        pending = json.loads(Path(PENDING_CONFIRM_FILE).read_text())
    except Exception:
        return {"ok": False, "msg": "Aucune question en attente."}
    if not pending.get("pending") or pending.get("qid") != qid:
        return {"ok": False, "msg": "Cette question n'est plus en attente (déjà répondue ou expirée)."}
    try:
        Path(CONFIRM_ANSWER_FILE).write_text(json.dumps({"qid": qid, "answer": answer}))
    except Exception as e:
        return {"ok": False, "msg": f"Erreur écriture réponse : {e}"}
    return {"ok": True, "msg": f"Réponse '{answer}' envoyée."}

def api_cancel_install(body):
    """Annule une installation lancée depuis le dashboard (bouton Annuler)."""
    try:
        pid = int(Path(INSTALL_PID_FILE).read_text().strip())
    except Exception:
        return {"ok":False,"msg":"Aucune installation en cours (PID introuvable)."}

    # Vérifier que le process existe encore et que c'est bien un bash lançant
    # notre installeur (évite de tuer un PID recyclé par un autre process).
    try:
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="ignore")
    except FileNotFoundError:
        try: Path(INSTALL_PID_FILE).unlink()
        except: pass
        progress_mark_inactive()
        return {"ok":True,"msg":"L'installation était déjà terminée."}

    if "install_ia_local" not in cmdline:
        try: Path(INSTALL_PID_FILE).unlink()
        except: pass
        return {"ok":False,"msg":"PID enregistré ne correspond plus à l'installeur — ignoré par sécurité."}

    try:
        # start_new_session=True au lancement ⇒ pid == pgid : on tue tout le
        # groupe (le script bash ET tous ses sous-process : apt, docker pull, etc.)
        os.killpg(pid, signal.SIGTERM)
        for _ in range(20):   # jusqu'à 2s pour un arrêt propre
            time.sleep(0.1)
            if not Path(f"/proc/{pid}").exists(): break
        else:
            os.killpg(pid, signal.SIGKILL)   # insiste si toujours vivant
    except ProcessLookupError:
        pass
    except Exception as e:
        return {"ok":False,"msg":f"Erreur lors de l'annulation : {e}"}

    try: Path(INSTALL_PID_FILE).unlink()
    except: pass
    progress_mark_inactive()
    return {"ok":True,"msg":"⛔ Installation annulée."}

def progress_mark_inactive():
    """Force progress.json à 'active:false' pour que l'UI se referme même si
    le script tué n'a pas eu le temps d'écrire son propre état final."""
    try:
        d = json.loads(Path(PROGRESS_FILE).read_text())
    except Exception:
        d = {}
    d["active"] = False
    d["label"] = "Installation annulée par l'utilisateur"
    try:
        Path(PROGRESS_FILE).write_text(json.dumps(d))
    except: pass

def api_change_pw(body):
    old=body.get("old",""); new=body.get("new",""); user=body.get("user","").strip()
    # Validation nom d'utilisateur : alphanum + tirets uniquement, 2-32 car.
    if not re.match(r"^[a-zA-Z0-9_-]{2,32}$",user):
        return {"ok":False,"msg":"Nom d'utilisateur invalide (2-32 car., alphanum et -_)"}
    if not _check_pw(_load_creds()["user"],old): return {"ok":False,"msg":"Mot de passe actuel incorrect"}
    if len(new)<6: return {"ok":False,"msg":"Nouveau mot de passe trop court (6 car. min)"}
    if len(new)>128: return {"ok":False,"msg":"Nouveau mot de passe trop long (128 car. max)"}
    _save_creds(user or _load_creds()["user"], new)
    with _sl: _sess.clear()
    return {"ok":True,"msg":"Mot de passe changé."}

WEB_DIR = Path(__file__).resolve().parent
# En déploiement, dashboard_server.py vit dans /usr/local/bin/ (voir
# $DASHBOARD_SCRIPT) tandis que les fichiers statiques sont copiés à part
# dans /usr/local/share/ia-installer/web/static/ (voir install_dashboard_script
# dans lib/dashboard.sh) — donc PAS à côté du script. On essaie l'emplacement
# de déploiement en premier, avec un repli sur "static/" à côté du script
# pour pouvoir tester en local directement depuis le dépôt.
_INSTALLED_STATIC = Path("/usr/local/share/ia-installer/web/static")
_DEV_STATIC = WEB_DIR / "static"
STATIC_DIR = _INSTALLED_STATIC if _INSTALLED_STATIC.is_dir() else _DEV_STATIC

# Fichiers proposés au téléchargement direct (ex: momory-cli.zip), générés par
# install_dashboard_script (lib/dashboard.sh) via shutil.make_archive.
DOWNLOADS_DIR = Path("/usr/local/share/ia-installer/web/downloads")

def _load_index_html():
    """Charge web/static/index.html et injecte le port courant."""
    return (STATIC_DIR / "index.html").read_text(encoding="utf-8").replace("__PORT__", str(PORT))

_STATIC_TYPES = {".css": "text/css; charset=utf-8", ".js": "application/javascript; charset=utf-8"}


# ── HTTP Handler ──────────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def _tok(self): return _get_tok(dict(self.headers))
    def _body(self):
        n=int(self.headers.get("Content-Length",0))
        if not n: return {}
        try: return json.loads(self.rfile.read(n))
        except: return {}
    # Headers de sécurité HTTP appliqués à toutes les réponses HTML
    _SEC_HEADERS={
        "X-Content-Type-Options":  "nosniff",
        "X-Frame-Options":         "DENY",
        "X-XSS-Protection":        "1; mode=block",
        "Referrer-Policy":         "no-referrer",
        "Content-Security-Policy": (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://fonts.gstatic.com; "
            "font-src https://fonts.gstatic.com; "
            "connect-src 'self'; "
            "img-src 'self' data:; "
            "frame-ancestors 'none'"
        ),
        "Cache-Control": "no-store, no-cache, must-revalidate",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    }

    def _send(self,c,ct,b,ex={}):
        if isinstance(b,str): b=b.encode()
        self.send_response(c)
        self.send_header("Content-Type",ct)
        self.send_header("Content-Length",str(len(b)))
        # Même origine — pas de CORS externe
        # Headers sécurité HTML uniquement
        if "text/html" in ct:
            for k,v in self._SEC_HEADERS.items(): self.send_header(k,v)
        for k,v in ex.items(): self.send_header(k,v)
        self.end_headers()
        self.wfile.write(b)
    def _j(self,d,c=200): self._send(c,"application/json; charset=utf-8",json.dumps(d,default=str))
    def _jauth(self,d):
        """JSON avec Set-Cookie"""
        b=json.dumps(d,default=str).encode()
        self.send_response(200)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
        for k,v in d.get("_headers",{}).items(): self.send_header(k,v)
        self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        p=urlparse(self.path).path
        if p=="/api/stats":
            with _lock: data=dict(_cache)
            self._send(200,"application/json; charset=utf-8",
                       json.dumps(data,default=str),{"Cache-Control":"no-store"})
        elif p=="/api/notes":
            self._j(_load_notes())
        elif p=="/api/power/history":
            period = parse_qs(urlparse(self.path).query).get("period", ["24h"])[0]
            if period not in ("24h", "7d", "30d"):
                period = "24h"
            self._j(get_power_history(period))
        elif p=="/api/power/settings":
            self._j(_power_settings())
        elif p.startswith("/download/"):
            # Anti path-traversal : on ne sert que des fichiers directement
            # dans DOWNLOADS_DIR, jamais un sous-chemin arbitraire.
            fname = Path(p[len("/download/"):]).name
            fpath = DOWNLOADS_DIR / fname
            if fpath.is_file() and fpath.suffix in (".zip", ".gz", ".tar"):
                self._send(
                    200, "application/octet-stream", fpath.read_bytes(),
                    {"Content-Disposition": f'attachment; filename="{fname}"'}
                )
            else:
                self.send_response(404); self.end_headers()
        elif p in("/","/index.html"):
            self._send(200,"text/html; charset=utf-8",_load_index_html().encode())
        elif p.startswith("/static/"):
            # Anti path-traversal : on résout et on vérifie que ça reste dans STATIC_DIR
            fname = Path(p[len("/static/"):]).name
            fpath = STATIC_DIR / fname
            ext = fpath.suffix
            if fpath.is_file() and ext in _STATIC_TYPES:
                self._send(200, _STATIC_TYPES[ext], fpath.read_bytes(), {"Cache-Control":"public, max-age=3600"})
            else:
                self.send_response(404); self.end_headers()
        else: self.send_response(404); self.end_headers()

    def do_POST(self):
        p=urlparse(self.path).path; body=self._body()

        # ── Public : login/logout ──
        if p=="/api/admin/login":
            u=body.get("user",""); pw=body.get("pass","")
            # Rate limiting : extraire l'IP du client
            client_ip=self.client_address[0]
            allowed,wait=_rl_check(client_ip)
            if not allowed:
                mins=wait//60; secs=wait%60
                self._j({"ok":False,"msg":f"Trop de tentatives. Réessayez dans {mins}min {secs}s."},429)
                return
            if _check_pw(u,pw):
                _rl_reset(client_ip)   # Succès → réinitialiser le compteur
                tok=_new_sess()
                b=json.dumps({"ok":True}).encode()
                self.send_response(200)
                self.send_header("Content-Type","application/json")
                self.send_header("Content-Length",str(len(b)))
                self.send_header("Set-Cookie",f"ia_sess={tok}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}")
                self.end_headers(); self.wfile.write(b)
            else:
                _rl_record(client_ip)   # Échec → enregistrer la tentative
                self._j({"ok":False,"msg":"Identifiants incorrects"},401)
            return

        if p=="/api/admin/logout":
            _del_sess(self._tok())
            b=json.dumps({"ok":True}).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
            self.send_header("Set-Cookie","ia_sess=; Path=/; Max-Age=0")
            self.end_headers(); self.wfile.write(b)
            return

        if p=="/api/notes":
            try:
                self._j(api_notes_action(body))
            except Exception as e:
                self._j({"ok":False,"msg":f"Erreur : {e}"})
            return

        if p=="/api/power/settings":
            try:
                price = float(body.get("kwh_price", 0.2016))
                provider = str(body.get("provider", ""))[:100]
                retention = int(body.get("retention_days", 90))
                retention = max(7, min(retention, 365))   # garde-fou raisonnable
                save_power_settings(price, provider, retention)
                self._j({"ok":True, **_power_settings()})
            except Exception as e:
                self._j({"ok":False,"msg":f"Erreur : {e}"})
            return

        # ── Protected ──
        if not p.startswith("/api/admin/"): self.send_response(404); self.end_headers(); return
        if not _valid_sess(self._tok()):
            self._j({"ok":False,"msg":"Session expirée"},401); return

        try:
            if p=="/api/admin/status":
                self._j({"ok":True,"data":api_admin_status()})
            elif p=="/api/admin/service":
                self._j(api_svc_action(body))
            elif p=="/api/admin/update":
                self._j(api_update(body))
            elif p=="/api/admin/models":
                self._j(api_models(body))
            elif p=="/api/admin/logs":
                self._j(api_logs(body))
            elif p=="/api/admin/change-password":
                self._j(api_change_pw(body))
            elif p=="/api/admin/install":
                self._j(api_launch_install(body))
            elif p=="/api/admin/install-cancel":
                self._j(api_cancel_install(body))
            elif p=="/api/admin/confirm-answer":
                self._j(api_confirm_answer(body))
            elif p=="/api/admin/set-installer-path":
                pth=body.get("path","").strip()
                if pth and os.path.isfile(pth):
                    try:
                        Path("/var/lib/ia-installer/installer-path.txt").write_text(pth)
                        self._j({"ok":True,"msg":f"Chemin enregistré : {pth}"})
                    except Exception as e:
                        self._j({"ok":False,"msg":str(e)})
                else:
                    self._j({"ok":False,"msg":f"Fichier introuvable : {pth}"})
            elif p=="/api/admin/system":
                self._j(api_system_action(body))
            else:
                self.send_response(404); self.end_headers()
        except Exception as e:
            self._j({"ok":False,"msg":str(e)},500)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length","0")
        self.end_headers()

    def do_HEAD(self): self.do_GET()

class Srv(http.server.ThreadingHTTPServer): pass

if __name__=="__main__":
    # Worker démarre immédiatement (fait 2 collect() avec sleep(1) entre les deux)
    threading.Thread(target=_worker,daemon=True).start()
    threading.Thread(target=power_monitor_loop,daemon=True).start()
    # Serveur HTTP démarre sans attendre le cache
    # Le cache sera prêt dans ~3s, les polls JS patienteront
    srv=Srv((BIND,PORT),Handler)
    lip=_run("ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[^ ]+'") or socket.gethostbyname(socket.gethostname())
    creds=_load_creds()
    print(f"[Momory Dashboard] http://127.0.0.1:{PORT}")
    if lip and lip!="127.0.0.1": print(f"[Momory Dashboard] http://{lip}:{PORT}  (LAN)")
    print(f"[Momory Dashboard] Identifiant admin : {creds['user']} / ia-local-admin")
    try: srv.serve_forever()
    except KeyboardInterrupt: srv.shutdown()

