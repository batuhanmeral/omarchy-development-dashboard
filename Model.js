.pragma library

var tabNames = ["Localhost", "Docker", "Images", "Databases"];
var maxRows = 4096;

function plain(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function text(value) {
    return value === undefined || value === null ? "Unknown" : String(value);
}

function portRanges(value) {
    if (!String(value || "").trim()) return [];
    return String(value).split(",").map(function (part) {
        var match = part.trim().match(/^(\d{1,5})(?:-(\d{1,5}))?$/);
        if (!match) throw new Error("Hidden ports must be ports or ranges separated by commas.");
        var lo = Number(match[1]);
        var hi = match[2] ? Number(match[2]) : lo;
        if (lo < 1 || hi > 65535 || lo > hi) throw new Error("Port range must be within 1–65535.");
        return [lo, hi];
    });
}

function config(raw) {
    raw = plain(raw) ? raw : {};
    var interval = Number(raw.refreshInterval === undefined ? 5 : raw.refreshInterval);
    var ranges;
    try { ranges = portRanges(raw.hiddenPorts); } catch (error) { ranges = []; }
    var selected = raw.visibleTabs === undefined ? tabNames : String(raw.visibleTabs).split(",");
    var tabs = tabNames.filter(function (name) { return selected.indexOf(name) !== -1; });
    return {
        refreshInterval: isFinite(interval) && interval >= 2 && interval <= 120 ? Math.round(interval) : 5,
        dockerEnabled: raw.dockerEnabled !== false,
        exposure: ["all", "localhost", "lan"].indexOf(raw.exposure) >= 0 ? raw.exposure : "all",
        hiddenPorts: String(raw.hiddenPorts || ""),
        ranges: ranges,
        visibleTabs: tabs.length ? tabs.join(",") : "Localhost",
        tabs: tabs.length ? tabs : ["Localhost"],
        sortBy: ["port", "name", "state"].indexOf(raw.sortBy) >= 0 ? raw.sortBy : "port",
        compact: raw.compact !== false,
        sqliteFiles: typeof raw.sqliteFiles === "string" ? raw.sqliteFiles : ""
    };
}

function validateSettings(raw) {
    var errors = [];
    if (raw.refreshInterval !== undefined) {
        var n = Number(raw.refreshInterval);
        if (!isFinite(n) || n < 2 || n > 120 || Math.floor(n) !== n)
            errors.push("Refresh interval must be an integer from 2 to 120 seconds.");
    }
    try { portRanges(raw.hiddenPorts); } catch (error) { errors.push(error.message); }
    if (raw.visibleTabs !== undefined && !tabNames.some(function (t) {
        return String(raw.visibleTabs).split(",").indexOf(t) !== -1;
    })) errors.push("Select at least one tab.");
    var files = String(raw.sqliteFiles || "").split("\n").filter(function (f) { return f.trim(); });
    if (files.length > 32 || files.some(function (f) { return f.charAt(0) !== "/" || f.indexOf("\0") >= 0; }))
        errors.push("SQLite needs at most 32 absolute file paths, one per line.");
    return errors;
}

function validIpv4(address) {
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(address)
        && address.split(".").every(function (n) { return Number(n) <= 255; });
}

function validAddress(address) {
    if (typeof address !== "string" || address.length > 128) return false;
    // ss reports interface-scoped IPv4 listeners too, e.g. systemd-resolved on 127.0.0.53%lo.
    var v4 = address.match(/^(\d{1,3}(?:\.\d{1,3}){3})(?:%[a-zA-Z0-9_.-]+)?$/);
    if (v4) return validIpv4(v4[1]);
    var mixed = address.match(/^[0-9a-fA-F:]+:(\d{1,3}(?:\.\d{1,3}){3})(?:%[a-zA-Z0-9_.-]+)?$/);
    if (mixed) return validIpv4(mixed[1]);
    // IPv6 syntax is checked fully in Python; this UI boundary also excludes URL delimiters.
    return address.indexOf(":") >= 0 && /^[0-9a-fA-F:]+(?:%[a-zA-Z0-9_.-]+)?$/.test(address);
}

function validPort(row) {
    return plain(row) && validAddress(row.address) && Number.isInteger(row.port)
        && row.port > 0 && row.port <= 65535 && typeof row.id === "string"
        && row.id === "tcp:" + row.address + ":" + row.port
        && Array.isArray(row.containerIds) && row.containerIds.every(function (id) { return /^[a-f0-9]{64}$/.test(id); });
}

function decode(raw, expected) {
    if (typeof raw !== "string" || raw.length > 2 * 1024 * 1024) throw new Error("Response size limit exceeded.");
    var result = JSON.parse(raw);
    if (!plain(result) || result.schemaVersion !== 1 || result.kind !== expected
            || typeof result.ok !== "boolean" || !Array.isArray(result.errors) || !plain(result.data))
        throw new Error("Invalid collector response.");
    if (result.errors.length > 32 || result.errors.some(function (e) { return typeof e !== "string"; }))
        throw new Error("Invalid collector diagnostics.");
    if (expected === "logs") {
        // Python caps logs at 32768 code points; astral characters count twice in UTF-16.
        if (result.ok && (typeof result.data.text !== "string" || result.data.text.length > 65536))
            throw new Error("Invalid log response.");
        return result;
    }
    var sections = ["ports", "containers", "images", "volumes", "sqlite"];
    var allowed = expected === "ports" ? ["ports", "sqlite"] : ["containers", "images", "volumes", "dockerStatus"];
    Object.keys(result.data).forEach(function (key) {
        if (allowed.indexOf(key) < 0) throw new Error("Unexpected inventory section.");
    });
    sections.forEach(function (section) {
        if (result.data[section] === undefined) return;
        var rows = result.data[section];
        if (!Array.isArray(rows) || rows.length > maxRows) throw new Error("Invalid inventory section.");
        var seen = Object.create(null);
        rows.forEach(function (row) {
            if (!plain(row) || typeof row.id !== "string" || !row.id || row.id.length > 4096 || seen[row.id])
                throw new Error("Invalid inventory identity.");
            seen[row.id] = true;
            if (section === "ports" && !validPort(row)) throw new Error("Invalid port.");
            if (section === "images" && (!Array.isArray(row.tags) || !row.tags.every(function (v) { return typeof v === "string"; }) || typeof row.used !== "boolean"))
                throw new Error("Invalid image.");
            if (section === "volumes" && (!Array.isArray(row.containers) || !Array.isArray(row.destinations)
                    || !row.containers.concat(row.destinations).every(function (v) { return typeof v === "string"; })))
                throw new Error("Invalid volume.");
            if (section === "containers") {
                if (!/^[a-f0-9]{64}$/.test(row.id) || !Array.isArray(row.publishedPorts)
                        || row.publishedPorts.length > maxRows || !row.publishedPorts.every(validPort))
                    throw new Error("Invalid container.");
            }
        });
    });
    return result;
}

function merge(current, data) {
    var next = {};
    Object.keys(current).forEach(function (key) { next[key] = current[key]; });
    ["ports", "containers", "images", "volumes", "sqlite", "dockerStatus"].forEach(function (key) {
        if (data[key] !== undefined && JSON.stringify(data[key]) !== JSON.stringify(current[key]))
            next[key] = data[key];
    });
    return next;
}

// Docker sections describe the daemon as of the last successful query. Once it is unreachable or
// switched off they are unknown, so they are emptied rather than shown as if still current.
function absorb(current, data) {
    if (data.dockerStatus === "unavailable" || data.dockerStatus === "disabled")
        data = { dockerStatus: data.dockerStatus, containers: [], images: [], volumes: [] };
    return merge(current, data);
}

function listeners(state, includeDocker) {
    var byId = Object.create(null);
    (state.ports || []).forEach(function (row) {
        var copy = {};
        Object.keys(row).forEach(function (key) { copy[key] = row[key]; });
        copy.containerIds = (row.containerIds || []).slice();
        byId[row.id] = copy;
    });
    if (includeDocker) (state.containers || []).forEach(function (container) {
        if (container.state !== "running") return;
        (container.publishedPorts || []).forEach(function (port) {
            var row = byId[port.id];
            if (!row) {
                row = {};
                Object.keys(port).forEach(function (key) { row[key] = port[key]; });
                row.containerIds = [];
                byId[port.id] = row;
            }
            if (row.containerIds.indexOf(container.id) === -1) row.containerIds.push(container.id);
            row.containerName = container.name;
            if (!row.database) row.database = container.database || null;
        });
    });
    return Object.keys(byId).map(function (key) { return byId[key]; });
}

function addressText(row) {
    return (row.address.indexOf(":") >= 0 ? "[" + row.address + "]" : row.address) + ":" + row.port;
}

function url(row, scheme) {
    var protocol = scheme || row.protocol;
    if (!validPort(row) || row.database || ["http", "https"].indexOf(protocol) < 0) return "";
    var host = row.address;
    var bare = host.split("%")[0];
    // A wildcard bind is reached on loopback, without the interface zone.
    if (bare === "0.0.0.0") host = "127.0.0.1";
    else if (bare === "::") host = "::1";
    else if (host.indexOf(":") < 0) host = bare;
    if (host.indexOf(":") >= 0) host = "[" + host.replace(/%/g, "%25") + "]";
    return protocol + "://" + host + ":" + row.port + "/";
}

function hidden(row, cfg) {
    return cfg.ranges.some(function (pair) { return row.port >= pair[0] && row.port <= pair[1]; })
        || (cfg.exposure === "localhost" && row.exposure !== "localhost")
        || (cfg.exposure === "lan" && row.exposure === "localhost");
}

function duration(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0));
    if (s < 60) return s + "s";
    if (s < 3600) return Math.floor(s / 60) + "m";
    if (s < 86400) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
    return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h";
}

function known(value) {
    return value !== undefined && value !== null && value !== "" && value !== "Unknown";
}

function imageTags(row) {
    var tags = (row.tags || []).filter(function (tag) { return tag.indexOf("<none>") < 0; });
    return tags.length ? tags.join(", ") : "untagged";
}

function containerTone(row) {
    if (row.health === "unhealthy" || row.state === "dead") return "urgent";
    if (row.state !== "running") return row.state === "restarting" || row.state === "paused" ? "warn" : "dim";
    return row.health === "starting" ? "warn" : "ok";
}

// One list row. Every field is a primitive so it can live in a QML ListModel.
function viewRow(row, kind) {
    var view = { id: row.id, kind: kind, lead: "", title: "", subtitle: "", badge: "", tone: "dim",
        rowState: row.state || "", exposure: "", url: "", copyText: "", containerId: "", port: row.port || 0 };
    var words = [];
    if (kind === "port") {
        var address = addressText(row);
        view.lead = String(row.port);
        view.title = row.containerName || (known(row.process) ? row.process : row.database || "Unknown process");
        view.subtitle = [row.address, row.database, row.containerName ? "container"
            : row.pid ? "pid " + row.pid : null, row.containerName || !known(row.owner) ? null : row.owner]
            .filter(known).join(" · ");
        view.exposure = row.exposure || "";
        view.badge = row.exposure === "localhost" ? "local" : row.exposure === "all" ? "exposed" : "lan";
        view.tone = row.exposure === "localhost" ? "info" : row.exposure === "all" ? "urgent" : "warn";
        view.url = url(row);
        view.copyText = view.url || address;
        view.containerId = (row.containerIds || [])[0] || "";
        words = [address, row.process, row.cwd];
    } else if (kind === "container") {
        var published = (row.publishedPorts || []).map(function (p) { return ":" + p.port; })
            .filter(function (p, i, all) { return all.indexOf(p) === i; });
        view.title = text(row.name);
        view.subtitle = [row.image, row.compose].concat(published).filter(known).join(" · ");
        view.badge = row.health || row.state || "unknown";
        view.tone = containerTone(row);
        view.copyText = text(row.name);
        view.containerId = row.id;
        words = [row.id, row.database];
    } else if (kind === "image") {
        view.title = imageTags(row);
        view.subtitle = row.size || "Unknown size";
        view.badge = row.used ? "in use" : "unused";
        view.tone = row.used ? "ok" : "dim";
        view.copyText = view.title === "untagged" ? row.id : view.title.split(", ")[0];
        words = [row.id];
    } else if (kind === "volume") {
        var users = row.containers || [];
        view.title = text(row.name);
        view.subtitle = users.length ? users.join(", ") : "Not used by any container";
        view.badge = users.length ? "attached" : "unattached";
        view.tone = users.length ? "info" : "dim";
        view.copyText = text(row.name);
        words = [row.mountpoint].concat(row.destinations || []);
    } else {
        view.title = text(row.name);
        view.subtitle = text(row.path);
        view.badge = row.state === "configured" ? "found" : "missing";
        view.tone = row.state === "configured" ? "ok" : "urgent";
        view.copyText = text(row.path);
        words = ["sqlite"];
    }
    view.haystack = [view.lead, view.title, view.subtitle, view.badge].concat(words)
        .filter(known).join(" ").toLowerCase();
    view.raw = JSON.stringify(row);
    return view;
}

// Label/value pairs for the detail view. Unknown values are left out instead of printed.
function facts(view, now) {
    var row;
    try { row = JSON.parse(view.raw); } catch (error) { return []; }
    if (!plain(row)) return [];
    var output = [];
    function add(label, value, copy) {
        if (!known(value)) return;
        output.push({ label: label, value: String(value), copy: String(copy === undefined ? value : copy) });
    }
    if (view.kind === "port") {
        add("Address", addressText(row));
        add("Exposure", { localhost: "This machine only", lan: "Reachable on one network address",
            all: "Reachable on every network interface" }[row.exposure]);
        add("Process", known(row.process) ? row.process + (row.pid ? " (pid " + row.pid + ")" : "")
            : "Not visible; owned by another user", known(row.process) ? row.process : "");
        add("Owner", row.owner);
        add("Working directory", row.cwd);
        if (row.startedAt) add("Running for", duration(now - row.startedAt));
        add("Container", row.containerName);
        add("Database", row.database);
        add("Container port", row.targetPort);
    } else if (view.kind === "container") {
        add("Name", row.name);
        add("Image", row.image);
        add("State", row.health ? row.state + " (" + row.health + ")" : row.state);
        add("CPU", row.cpu);
        add("Memory", row.memory);
        add("Restart policy", row.restart);
        add("Compose project", row.compose);
        add("Published", (row.publishedPorts || []).map(addressText).join(", "));
        add("Database", row.database);
        add("ID", String(row.id).slice(0, 12), row.id);
    } else if (view.kind === "image") {
        add("Tags", imageTags(row));
        add("Size", row.size);
        add("Usage", row.used ? "Used by a container" : "Not used by any container");
        add("ID", String(row.id).slice(0, 19), row.id);
    } else if (view.kind === "volume") {
        add("Name", row.name);
        add("Used by", (row.containers || []).join(", "));
        add("Mounted at", (row.destinations || []).join(", "));
        add("Host path", row.mountpoint);
    } else {
        add("File", row.name);
        add("Path", row.path);
        add("Status", row.state === "configured" ? "File found" : "File not found");
        add("Privacy", "Contents are never read", "");
    }
    return output;
}

function filters(tab) {
    if (tab === "Localhost") return [{ value: "all", label: "All" }, { value: "localhost", label: "Local" },
        { value: "lan", label: "Exposed" }];
    if (tab === "Images") return [{ value: "all", label: "All" }, { value: "images", label: "Images" },
        { value: "volumes", label: "Volumes" }, { value: "unused", label: "Unused" }];
    return [{ value: "all", label: "All" }, { value: "running", label: "Running" },
        { value: "stopped", label: "Stopped" }];
}

function rows(state, tab, query, filter, cfg) {
    var output = [];
    if (tab === "Localhost" || tab === "Databases") {
        listeners(state, cfg.dockerEnabled).forEach(function (row) {
            if (!hidden(row, cfg) && (tab !== "Databases" || row.database)) output.push(viewRow(row, "port"));
        });
    }
    if (cfg.dockerEnabled && (tab === "Docker" || tab === "Databases")) {
        (state.containers || []).forEach(function (row) {
            if (tab === "Databases" && (!row.database || output.some(function (r) { return r.containerId === row.id; }))) return;
            output.push(viewRow(row, "container"));
        });
    }
    if (tab === "Databases") (state.sqlite || []).forEach(function (row) { output.push(viewRow(row, "sqlite")); });
    if (tab === "Images" && cfg.dockerEnabled) {
        (state.images || []).forEach(function (row) { output.push(viewRow(row, "image")); });
        (state.volumes || []).forEach(function (row) { output.push(viewRow(row, "volume")); });
    }
    var search = String(query || "").toLowerCase().trim();
    output = output.filter(function (row) {
        var matches = !search || row.haystack.indexOf(search) >= 0;
        if (filter === "running") matches = matches && row.rowState === "running";
        if (filter === "stopped") matches = matches && row.rowState !== "running";
        if (filter === "localhost") matches = matches && row.exposure === "localhost";
        if (filter === "lan") matches = matches && row.exposure !== "localhost";
        if (filter === "images") matches = matches && row.kind === "image";
        if (filter === "volumes") matches = matches && row.kind === "volume";
        if (filter === "unused") matches = matches && (row.badge === "unused" || row.badge === "unattached");
        return matches;
    });
    var order = ["port", "container", "image", "volume", "sqlite"];
    output.sort(function (a, b) {
        if (a.kind !== b.kind) return order.indexOf(a.kind) - order.indexOf(b.kind);
        if (cfg.sortBy === "port" && a.port !== b.port) return a.port - b.port;
        if (cfg.sortBy === "state" && a.rowState !== b.rowState) return a.rowState.localeCompare(b.rowState);
        return a.title.localeCompare(b.title) || a.id.localeCompare(b.id);
    });
    return output;
}

function counts(state, cfg) {
    var output = {};
    tabNames.forEach(function (tab) { output[tab] = rows(state, tab, "", "all", cfg).length; });
    return output;
}

function summary(state, cfg) {
    var listening = rows(state, "Localhost", "", "all", cfg).length + " listening";
    var containers = cfg.dockerEnabled ? state.containers || [] : [];
    if (!containers.length) return listening;
    var running = containers.filter(function (row) { return row.state === "running"; }).length;
    return listening + " · " + running + " of " + containers.length + " containers running";
}

// Only a failed port query makes the bar widget urgent. A missing or stopped Docker daemon is a
// normal state on many machines and is explained inside the Docker tabs instead.
function barError(errors) {
    return String((errors || {}).ports || "");
}

function dockerNotice(state, errors, cfg) {
    if (!cfg.dockerEnabled) return "Docker integration is turned off in settings.";
    var reason = (errors || {}).docker || (errors || {}).assets || "";
    if ((state || {}).dockerStatus === "unavailable") return "Docker is not reachable: " + (reason || "unknown reason");
    return reason;
}

// The bar and panel glyph (Nerd Font). Kept in one place so both stay the same.
var icon = "\u{f0200}"; // nf-md-ethernet

// Status colours from the theme's colors.toml (red/green/yellow/blue = color1..4), so badges
// follow the active Omarchy theme. Fallbacks are mid-tone hues readable on light and dark.
function palette(toml) {
    var output = { red: "#e5534b", green: "#57ab5a", yellow: "#c69026", blue: "#539bf5" };
    var keys = { color1: "red", red: "red", color2: "green", green: "green",
        color3: "yellow", yellow: "yellow", color4: "blue", blue: "blue" };
    String(toml || "").split("\n").forEach(function (line) {
        var match = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})["']?\s*$/);
        if (match && keys[match[1]]) output[keys[match[1]]] = match[2];
    });
    return output;
}

function tabLabel(tab) {
    return tab === "Localhost" ? "Ports" : tab;
}

function emptyText(tab, query, filter, notice, sampled) {
    if (!sampled) return "Collecting local services…";
    if (notice && tab !== "Localhost" && (tab !== "Databases" || !String(query || "").trim())) return notice;
    if (String(query || "").trim()) return "Nothing matches “" + String(query).trim() + "”.";
    if (filter !== "all") return "Nothing matches this filter.";
    if (tab === "Localhost") return "Nothing is listening on a TCP port.";
    if (tab === "Docker") return "No containers.";
    if (tab === "Images") return "No images or volumes.";
    return "No databases found.\nSQLite files can be added in settings.";
}

// Turns one finished collector run into a decoded result and a user-facing diagnostic.
function outcome(scope, raw, exitCode, timedOut) {
    if (timedOut) return { result: null, error: "Collector timed out; showing previous data." };
    if (exitCode === -1 && (typeof raw !== "string" || !raw.trim()))
        return { result: null, error: "Collector could not start; is python3 installed?" };
    if (typeof raw !== "string" || !raw.trim())
        return { result: null, error: "Collector failed (exit " + exitCode + ")." };
    var result;
    try { result = decode(raw, scope); } catch (error) {
        return { result: null, error: "Invalid collector response: " + error.message };
    }
    var message = result.errors.join("\n");
    if (!message && exitCode !== 0) message = "Collector failed (exit " + exitCode + ").";
    return { result: result, error: message };
}

// A job is stale once settings changed or, for logs, once the log view moved on.
function current(job, generation, logGeneration) {
    return !!job && job.generation === generation && (job.scope !== "logs" || job.logToken === logGeneration);
}

function sync(model, next) {
    var desired = Object.create(null);
    next.forEach(function (row) { desired[row.id] = true; });
    for (var i = model.count - 1; i >= 0; i--) {
        if (!desired[model.get(i).id]) model.remove(i);
    }
    for (var index = 0; index < next.length; index++) {
        var row = next[index];
        if (index >= model.count) { model.append(row); continue; }
        if (model.get(index).id !== row.id) {
            var existing = -1;
            for (var j = index + 1; j < model.count; j++) {
                if (model.get(j).id === row.id) { existing = j; break; }
            }
            if (existing >= 0) model.move(existing, index, 1);
            else { model.insert(index, row); continue; }
        }
        var current = model.get(index);
        if (Object.keys(row).some(function (key) { return current[key] !== row[key]; })) model.set(index, row);
    }
}

function nextScope(now, opened, cfg, last, busy) {
    if (busy) return "";
    var portInterval = (opened ? cfg.refreshInterval : Math.max(30, cfg.refreshInterval)) * 1000;
    var scopes = [["ports", portInterval]];
    if (cfg.dockerEnabled) {
        scopes.push(["docker", opened ? 15000 : 60000]);
        if (opened) scopes.push(["assets", 60000]);
    }
    var selected = "";
    var oldest = Infinity;
    scopes.forEach(function (entry) {
        var previous = last[entry[0]];
        if (previous !== undefined && now - previous < entry[1]) return;
        var timestamp = previous === undefined ? -Infinity : previous;
        if (!selected || timestamp < oldest) {
            selected = entry[0];
            oldest = timestamp;
        }
    });
    return selected;
}
