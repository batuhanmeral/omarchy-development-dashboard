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

function validAddress(address) {
    if (typeof address !== "string" || address.length > 128) return false;
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(address)) {
        return address.split(".").every(function (n) { return Number(n) <= 255; });
    }
    var mixed = address.match(/^[0-9a-fA-F:]+:(\d{1,3}(?:\.\d{1,3}){3})(?:%[a-zA-Z0-9_.-]+)?$/);
    if (mixed) return validAddress(mixed[1]);
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
        if (result.ok && (typeof result.data.text !== "string" || result.data.text.length > 32768))
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
    if (host === "0.0.0.0") host = "127.0.0.1";
    if (host === "::") host = "::1";
    if (host.indexOf(":") >= 0) host = "[" + host.replace(/%/g, "%25") + "]";
    return protocol + "://" + host + ":" + row.port + "/";
}

function hidden(row, cfg) {
    return cfg.ranges.some(function (pair) { return row.port >= pair[0] && row.port <= pair[1]; })
        || (cfg.exposure === "localhost" && row.exposure !== "localhost")
        || (cfg.exposure === "lan" && row.exposure === "localhost");
}

function viewRow(row, kind) {
    var title, subtitle, badge, detail, link = "", copy = "", containerId = "";
    if (kind === "port") {
        title = row.database || row.containerName || row.process || "Unknown";
        subtitle = addressText(row);
        badge = row.exposure;
        link = url(row);
        copy = link || subtitle;
        containerId = (row.containerIds || [])[0] || "";
        detail = "Bind: " + subtitle + "\nExposure: " + text(row.exposure)
            + "\nProcess: " + text(row.process) + "\nPID: " + text(row.pid)
            + "\nOwner: " + text(row.owner) + "\nWorking directory: " + text(row.cwd)
            + "\nUptime: " + (row.uptimeSeconds == null ? "Unknown" : row.uptimeSeconds + " s")
            + "\nContainer: " + text(row.containerName) + "\nProtocol: " + text(row.protocol);
    } else if (kind === "container") {
        title = row.name;
        subtitle = row.image;
        badge = row.health || row.state;
        containerId = row.id;
        detail = "Container: " + text(row.name) + "\nID: " + row.id + "\nImage: " + text(row.image)
            + "\nState: " + text(row.state) + "\nHealth: " + text(row.health)
            + "\nCPU: " + text(row.cpu) + "\nMemory: " + text(row.memory)
            + "\nRestart policy: " + text(row.restart) + "\nCompose project: " + text(row.compose)
            + "\nPublished TCP: " + ((row.publishedPorts || []).map(addressText).join(", ") || "None");
    } else if (kind === "image") {
        title = (row.tags || []).join(", ");
        subtitle = row.size || "Unknown size";
        badge = row.used ? "in use" : "unused";
        detail = "Tags: " + title + "\nID: " + row.id + "\nSize: " + subtitle + "\nUsage: " + badge;
    } else if (kind === "volume") {
        title = row.name;
        subtitle = (row.containers || []).join(", ") || "Unattached";
        badge = "volume";
        detail = "Volume: " + title + "\nContainers: " + subtitle + "\nHost mount: " + text(row.mountpoint)
            + "\nContainer mounts: " + (row.destinations || []).join(", ") + "\nSize: Unknown (not estimated)";
    } else {
        title = row.name;
        subtitle = row.path;
        badge = row.state;
        detail = "SQLite: " + subtitle + "\nState: " + badge + "\nFile contents are never read.";
    }
    return { id: row.id, title: text(title), subtitle: text(subtitle), badge: text(badge),
        state: row.state || "", rowState: row.state || "", kind: kind, detail: detail, url: link, copyText: copy,
        containerId: containerId, port: row.port || 0,
        raw: JSON.stringify(row) };
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
        var matches = !search || (row.title + " " + row.subtitle + " " + row.detail).toLowerCase().indexOf(search) >= 0;
        if (filter === "running") matches = matches && row.state === "running";
        if (filter === "stopped") matches = matches && row.state !== "running";
        if (filter === "localhost") matches = matches && row.badge === "localhost";
        if (filter === "lan") matches = matches && row.badge !== "localhost";
        if (filter === "images") matches = matches && row.kind === "image";
        if (filter === "volumes") matches = matches && row.kind === "volume";
        if (filter === "unused") matches = matches && row.badge === "unused";
        return matches;
    });
    output.sort(function (a, b) {
        if (cfg.sortBy === "port" && a.port !== b.port) return a.port - b.port;
        if (cfg.sortBy === "state" && a.state !== b.state) return a.state.localeCompare(b.state);
        return a.title.localeCompare(b.title) || a.id.localeCompare(b.id);
    });
    return output;
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
