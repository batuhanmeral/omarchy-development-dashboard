.pragma library

var pluginId = "io.github.batuhanmeral.development-dashboard";
var legacyPluginId = "io.github.batuhanmeral.devports";
var displayName = "Development Dashboard";
var tagline = "Your development environment, one panel.";
var tabNames = ["Localhost", "Docker", "Images", "Databases", "Projects", "Tools"];
var terminals = ["default", "alacritty", "foot", "ghostty", "kitty"];

function validPath(path) {
    return typeof path === "string" && path.charAt(0) === "/" && path.length <= 4096
        && !/[\x00-\x1f\x7f]/.test(path) && !/[\uD800-\uDFFF]/.test(path.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, "")) && path.split("/").indexOf("..") < 0;
}

function inside(path, parent) {
    return path === parent || path.indexOf(parent.replace(/\/+$/, "") + "/") === 0;
}

function validRoot(path) {
    return validPath(path) && path !== "/" && !["/proc", "/sys", "/dev", "/run", "/boot", "/etc", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/var/lib/docker"].some(function (root) { return inside(path, root); });
}

function lines(value) {
    return String(value || "").split("\n").map(function (s) { return s.trim(); }).filter(function (s) { return s !== ""; });
}

function customLines(value) {
    return lines(value).filter(function (s) { return s.charAt(0) !== "#"; });
}

function parseCustomTools(value) {
    var input = customLines(value);
    if (input.length > 8) throw new Error("Use at most 8 custom AI tools.");
    return input.map(function (line, index) {
        var parts = line.split("|").map(function (part) { return part.trim(); });
        var args = parts.length === 3 && parts[2] ? parts[2].split(/\s+/) : [];
        if (parts.length < 2 || parts.length > 3 || !parts[0] || parts[0].length > 48
                || /[\x00-\x1f\x7f]/.test(line) || !(/^[A-Za-z0-9._+-]{1,64}$/.test(parts[1]) || validPath(parts[1]))
                || args.length > 16 || args.some(function (arg) { return arg.length > 256; }))
            throw new Error("Invalid custom tool definition on line " + (index + 1) + ".");
        return { id: "custom-" + (index + 1), name: parts[0], executable: parts[1], args: args };
    });
}
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
    if (!(Number(raw.settingsVersion) >= 2)) selected = selected.concat(["Projects", "Tools"]);
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
        sqliteFiles: typeof raw.sqliteFiles === "string" ? raw.sqliteFiles : "",
        settingsVersion: 2,
        managementEnabled: raw.managementEnabled === true,
        projectRoots: lines(raw.projectRoots).filter(validRoot).slice(0, 16).join("\n"),
        projectDepth: Number.isInteger(Number(raw.projectDepth)) && Number(raw.projectDepth) >= 1 && Number(raw.projectDepth) <= 4 ? Number(raw.projectDepth) : 3,
        terminal: terminals.indexOf(raw.terminal) >= 0 ? raw.terminal : "default",
        editor: typeof raw.editor === "string" && raw.editor.length <= 256 && !/[\x00-\x1f\x7f]/.test(raw.editor) ? raw.editor : "",
        customTools: typeof raw.customTools === "string" ? raw.customTools : ""
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
    if (lines(raw.projectRoots).length > 16 || lines(raw.projectRoots).some(function (p) { return !validRoot(p); }))
        errors.push("Project folders need at most 16 absolute, permitted directory paths.");
    if (raw.projectDepth !== undefined && (!Number.isInteger(Number(raw.projectDepth)) || Number(raw.projectDepth) < 1 || Number(raw.projectDepth) > 4))
        errors.push("Scan depth must be an integer from 1 to 4.");
    if (raw.terminal !== undefined && terminals.indexOf(raw.terminal) < 0) errors.push("Select a supported terminal.");
    if (raw.editor !== undefined && (typeof raw.editor !== "string" || raw.editor.length > 256 || /[\x00-\x1f\x7f]/.test(raw.editor)))
        errors.push("Editor must be at most 256 characters without control characters.");
    try { parseCustomTools(raw.customTools); } catch (error) { errors.push(error.message); }
    return errors;
}

function legacySettings(raw) {
    raw = plain(raw) ? raw : {};
    var safe = {};
    var types = {refreshInterval:"number", dockerEnabled:"boolean", exposure:"string", hiddenPorts:"string", visibleTabs:"string", sortBy:"string", compact:"boolean", sqliteFiles:"string"};
    Object.keys(types).forEach(function (key) { if (typeof raw[key] === types[key]) safe[key] = raw[key]; });
    return config(safe);
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

function validExpectedPort(entry) {
    return plain(entry) && Number.isInteger(entry.port) && entry.port >= 1 && entry.port <= 65535
        && [".env", ".env.local", ".env.development", "package.json", "docker-compose.yml", "compose.yaml"].indexOf(entry.source) >= 0;
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
    var sections = ["ports", "containers", "images", "volumes", "sqlite", "projects", "tools"];
    var allowed = {ports:["ports", "sqlite"], docker:["containers", "images", "volumes", "dockerStatus"],
        assets:["containers", "images", "volumes", "dockerStatus"], projects:["projects", "skipped"], tools:["tools"], legacy:["legacy"]}[expected];
    if (!allowed) throw new Error("Unknown inventory scope.");
    if (expected === "legacy" && (!plain(result.data.legacy) || typeof result.data.legacy.found !== "boolean"
            || typeof result.data.legacy.installed !== "boolean" || (result.data.legacy.found && !plain(result.data.legacy.settings))))
        throw new Error("Invalid legacy settings.");
    if (result.data.skipped !== undefined && (!Number.isInteger(result.data.skipped) || result.data.skipped < 0)) throw new Error("Invalid skipped count.");
    Object.keys(result.data).forEach(function (key) {
        if (allowed.indexOf(key) < 0) throw new Error("Unexpected inventory section.");
    });
    sections.forEach(function (section) {
        if (result.data[section] === undefined) return;
        var rows = result.data[section];
        if (!Array.isArray(rows) || rows.length > maxRows) throw new Error("Invalid inventory section.");
        var seen = Object.create(null);
        rows.forEach(function (row) {
            if (!plain(row) || typeof row.id !== "string" || !row.id || row.id.length > (section === "projects" ? 4104 : 4096) || seen[row.id])
                throw new Error("Invalid inventory identity.");
            seen[row.id] = true;
            if (section === "projects" && (!validPath(row.path) || row.id !== "project:" + row.path
                    || typeof row.name !== "string" || (row.expectedPorts !== undefined
                        && (!Array.isArray(row.expectedPorts) || row.expectedPorts.length > 16 || !row.expectedPorts.every(validExpectedPort)))
                    || ["clean", "dirty", "unknown"].indexOf(row.gitState) < 0)) throw new Error("Invalid project.");
            if (section === "tools" && (!/^[a-z0-9-]{1,40}$/.test(row.id) || typeof row.name !== "string" || typeof row.available !== "boolean")) throw new Error("Invalid tool.");
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
    ["ports", "containers", "images", "volumes", "sqlite", "dockerStatus", "projects", "tools", "legacy", "skipped"].forEach(function (key) {
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
function viewRow(row, kind, state, cfg, index) {
    var view = { id: row.id, kind: kind, lead: "", title: "", subtitle: "", badge: "", tone: "dim",
        rowState: row.state || "", exposure: "", url: "", copyText: "", containerId: "", port: row.port || 0 };
    index = index || (state ? serviceIndex(state, cfg || config({})) : null);
    var associations = index ? kind === "container" ? index.containers : index.ports : {};
    view.projectPath = kind === "project" ? row.path : associations[row.id] !== undefined ? associations[row.id]
        : projectPath(state || {}, kind === "container" ? row.composeDir : row.cwd, index);
    view.ownedByUser = row.ownedByUser === true;
    view.startTicks = row.startTicks || "";
    view.command = row.command || "";
    view.serviceCount = kind === "project" && index ? indexedServices(index, row.path, cfg || config({})).length : 0;
    view.portConflicts = "";
    var words = [];
    if (kind === "project") {
        view.title = row.name;
        view.subtitle = row.path;
        view.projectPath = row.path;
        view.badge = (row.branch || "unknown") + (row.gitState === "dirty" ? "*" : "");
        view.tone = row.conflicts ? "urgent" : row.gitState === "dirty" ? "warn" : row.gitState === "clean" ? "ok" : "dim";
        var conflicts = index ? portConflicts(state, row, cfg || config({}), index) : [];
        if (conflicts.length) {
            view.badge += " !";
            view.tone = "warn";
            view.portConflicts = conflicts.map(function (item) { return ":" + item.port + " · " + item.source + " · " + item.holder; }).join("\n");
        }
        view.copyText = row.path;
        words = [row.root, row.branch];
    } else if (kind === "tool") {
        view.title = row.name;
        view.subtitle = row.available ? row.path || row.executable : row.reason || "not found";
        view.badge = row.available ? "available" : "missing";
        view.tone = row.available ? "ok" : "dim";
        view.copyText = row.path || row.executable || "";
        words = [row.id, row.executable];
    } else if (kind === "port") {
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
        add("PID", row.pid);
        add("Owner", row.owner);
        add("Command", row.command);
        add("Project", view.projectPath);
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
        add("Exposed ports", (row.exposedPorts || []).join(", "));
        add("Compose directory", row.composeDir);
        add("Project", view.projectPath);
        add("ID", String(row.id).slice(0, 12), row.id);
    } else if (view.kind === "project") {
        add("Path", row.path);
        add("Branch", (row.branch || "unknown") + (row.detached ? " (detached)" : "") + " · " + (row.ahead || 0) + " ahead / " + (row.behind || 0) + " behind");
        add("Working tree", row.gitState + " · " + (row.changed || 0) + " changed · " + (row.untracked || 0) + " untracked · " + (row.conflicts || 0) + " conflicts");
        add("Root", row.root);
        add("Services", view.serviceCount || 0);
        add("Port conflicts", view.portConflicts);
    } else if (view.kind === "tool") {
        add("Executable", row.executable); add("Path", row.path); add("Status", row.available ? "Available" : row.reason || "not found");
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
    if (tab === "Projects") return [{value:"all",label:"All"},{value:"active",label:"Active"},{value:"dirty",label:"Dirty"},{value:"conflicts",label:"Conflicts"}];
    if (tab === "Tools") return [{value:"all",label:"All"},{value:"available",label:"Available"}];
    if (tab === "Localhost") return [{ value: "all", label: "All" }, { value: "localhost", label: "Local" },
        { value: "lan", label: "Exposed" }];
    if (tab === "Images") return [{ value: "all", label: "All" }, { value: "images", label: "Images" },
        { value: "volumes", label: "Volumes" }, { value: "unused", label: "Unused" }];
    return [{ value: "all", label: "All" }, { value: "running", label: "Running" },
        { value: "stopped", label: "Stopped" }];
}

function rows(state, tab, query, filter, cfg, index) {
    var output = [];
    index = index || (["Localhost", "Docker", "Databases", "Projects"].indexOf(tab) >= 0 ? serviceIndex(state, cfg) : null);
    if (tab === "Localhost" || tab === "Databases") {
        index.listeners.forEach(function (row) {
            if (!hidden(row, cfg) && (tab !== "Databases" || row.database)) output.push(viewRow(row, "port", state, cfg, index));
        });
    }
    if (cfg.dockerEnabled && (tab === "Docker" || tab === "Databases")) {
        (state.containers || []).forEach(function (row) {
            if (tab === "Databases" && (!row.database || output.some(function (r) { return r.containerId === row.id; }))) return;
            output.push(viewRow(row, "container", state, cfg, index));
        });
    }
    if (tab === "Databases") (state.sqlite || []).forEach(function (row) { output.push(viewRow(row, "sqlite")); });
    if (tab === "Images" && cfg.dockerEnabled) {
        (state.images || []).forEach(function (row) { output.push(viewRow(row, "image")); });
        (state.volumes || []).forEach(function (row) { output.push(viewRow(row, "volume")); });
    }
    if (tab === "Projects") (state.projects || []).forEach(function (row) { output.push(viewRow(row, "project", state, cfg, index)); });
    if (tab === "Tools") (state.tools || []).forEach(function (row) { output.push(viewRow(row, "tool", state, cfg)); });
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
        if (filter === "active") matches = matches && row.serviceCount > 0;
        if (filter === "dirty") matches = matches && JSON.parse(row.raw).gitState === "dirty";
        if (filter === "conflicts") matches = matches && !!row.portConflicts;
        if (filter === "available") matches = matches && row.badge === "available";
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
    var index = serviceIndex(state, cfg);
    tabNames.forEach(function (tab) {
        if (tab === "Projects") output[tab] = (state.projects || []).length;
        else if (tab === "Tools") output[tab] = (state.tools || []).length;
        else output[tab] = rows(state, tab, "", "all", cfg, index).length;
    });
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
    return {Localhost:"Ports",Databases:"DBs",Tools:"AI"}[tab] || tab;
}

function emptyText(tab, query, filter, notice, sampled, cfg) {
    if (notice && (tab === "Projects" || tab === "Tools")) return notice;
    if (tab === "Projects") {
        if (!cfg || !lines(cfg.projectRoots).length) return "No project folders yet. Add one in settings (s).";
        if (!sampled) return "Scanning projects…";
    }
    if (tab === "Tools" && !sampled) return "Detecting AI tools…";
    if (!sampled) return "Collecting local services…";
    if (notice && ["Docker", "Images", "Databases"].indexOf(tab) >= 0 && (tab !== "Databases" || !String(query || "").trim())) return notice;
    if (String(query || "").trim()) return "Nothing matches “" + String(query).trim() + "”.";
    if (filter !== "all") return "Nothing matches this filter.";
    if (tab === "Localhost") return "Nothing is listening on a TCP port.";
    if (tab === "Docker") return "No containers.";
    if (tab === "Images") return "No images or volumes.";
    if (tab === "Projects") return "No Git projects found in these folders.";
    if (tab === "Tools") return "No AI tools found. Add custom tools in settings.";
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
    if (opened) {
        if (lines(cfg.projectRoots).length) scopes.push(["projects", 60000]);
        scopes.push(["tools", 300000]);
        if (last.legacy === undefined) scopes.push(["legacy", 3600000]);
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

function tabKey(key, cfg) {
    var tab = /^[1-6]$/.test(String(key)) ? tabNames[Number(key) - 1] : "";
    return tab && (!cfg || cfg.tabs.indexOf(tab) >= 0) ? tab : "";
}

function decodeAction(raw) {
    if (typeof raw !== "string" || raw.length > 2 * 1024 * 1024) throw new Error("Response size limit exceeded.");
    var result = JSON.parse(raw);
    if (!plain(result) || result.schemaVersion !== 1 || result.kind !== "action" || typeof result.action !== "string"
            || !result.action || typeof result.ok !== "boolean" || !plain(result.data) || !Array.isArray(result.errors)
            || result.errors.length > 32 || result.errors.some(function (e) { return typeof e !== "string"; }))
        throw new Error("Invalid action response.");
    return result;
}

// Inventory arrays are replaced by merge(), never edited in place. Keep only the latest
// association index; view-only settings are applied when reading it, not cached here.
var serviceCache = null;

function serviceIndex(state, cfg) {
    if (serviceCache && serviceCache.projectsSource === state.projects && serviceCache.portsSource === state.ports
            && serviceCache.containersSource === state.containers && serviceCache.dockerEnabled === cfg.dockerEnabled)
        return serviceCache;
    var index = {projectsSource:state.projects, portsSource:state.ports, containersSource:state.containers,
        dockerEnabled:cfg.dockerEnabled, paths:(state.projects || []).map(function (p) { return p.path; }).filter(validPath)
            .sort(function (a, b) { return b.length - a.length; }),
        ports:Object.create(null), containers:Object.create(null), services:Object.create(null), listeners:listeners(state, cfg.dockerEnabled),
        byPort:Object.create(null), containerRows:Object.create(null)};
    function assign(row, kind, path) {
        var match = projectPath(state, path, index);
        (kind === "port" ? index.ports : index.containers)[row.id] = match;
        if (!match) return;
        if (!index.services[match]) index.services[match] = [];
        index.services[match].push({row:row, kind:kind});
    }
    index.listeners.forEach(function (row) {
        assign(row, "port", row.cwd);
        if (!index.byPort[row.port]) index.byPort[row.port] = [];
        index.byPort[row.port].push(row);
    });
    if (cfg.dockerEnabled) (state.containers || []).forEach(function (row) {
        index.containerRows[row.id] = row;
        assign(row, "container", row.composeDir);
    });
    serviceCache = index;
    return index;
}

function portConflicts(state, project, cfg, index) {
    index = index || serviceIndex(state, cfg);
    var output = [];
    (project.expectedPorts || []).forEach(function (entry) {
        var holders = Object.create(null);
        function add(holder) {
            if (holders[holder]) return;
            holders[holder] = true;
            output.push({port:entry.port, source:entry.source, holder:holder});
        }
        (index.byPort[entry.port] || []).forEach(function (row) {
            if (row.containerIds.length && cfg.dockerEnabled) {
                row.containerIds.forEach(function (id) {
                    var container = index.containerRows[id];
                    if (index.containers[id] !== project.path)
                        add(container ? container.name || id.slice(0, 12) : row.containerName || id.slice(0, 12));
                });
            } else if (index.ports[row.id] !== project.path) {
                add(row.containerName || row.process || addressText(row));
            }
        });
    });
    return output;
}

function projectPath(state, path, index) {
    if (!validPath(path)) return "";
    var paths = index ? index.paths : (state.projects || []).map(function (p) { return p.path; }).filter(validPath)
        .sort(function (a, b) { return b.length - a.length; });
    for (var i = 0; i < paths.length; i++) if (inside(path, paths[i])) return paths[i];
    return "";
}

function indexedServices(index, path, cfg) {
    return (index.services[path] || []).filter(function (service) { return service.kind !== "port" || !hidden(service.row, cfg); });
}

function projectServices(state, path, cfg, index) {
    cfg = cfg || config({});
    index = index || serviceIndex(state, cfg);
    return indexedServices(index, path, cfg).map(function (service) { return viewRow(service.row, service.kind, state, cfg, index); });
}


function rawRow(view) {
    if (view && typeof view.raw === "string") {
        try { return JSON.parse(view.raw); } catch (error) { return {}; }
    }
    return view || {};
}

function canManage(view, cfg) {
    if (!cfg.managementEnabled || !view) return false;
    var row = rawRow(view);
    if (view.kind === "container") return cfg.dockerEnabled && /^[a-f0-9]{64}$/.test(row.id);
    return view.kind === "port" && row.ownedByUser === true && !row.containerName && !(row.containerIds || []).length
        && Number.isInteger(row.pid) && row.pid >= 2 && row.pid <= 4194304 && typeof row.startTicks === "string" && /^\d{1,20}$/.test(row.startTicks || "");
}

function availableActions(view, cfg, state) {
    if (!view) return [];
    var row = rawRow(view), output = [];
    function add(id, label, key, confirm, destructive, extra) {
        output.push(Object.assign({id:id, label:label, key:key || "", confirm:!!confirm, destructive:!!destructive}, extra || {}));
    }
    if (view.kind === "container" && cfg.dockerEnabled) {
        if (canManage(view, cfg)) {
            if (row.state !== "running" && row.state !== "restarting" && row.state !== "paused") add("start", "Start", "u");
            else { add("stop", "Stop", "x", true, true); add("restart", "Restart", "R", true, true); }
        }
        (row.publishedPorts || []).forEach(function (p) {
            var target = url(Object.assign({}, p, {database:null}), "http");
            if (target) add("open", "Open :" + p.port, "", false, false, {url:target, raw:JSON.stringify(Object.assign({}, p, {database:null}))});
        });
    }
    if (view.kind === "port" && canManage(view, cfg)) add("terminate", "Stop process", "x", true, true);
    if (view.kind === "project") {
        add("terminal", "Terminal", "t"); add("editor", "Editor", "e"); add("files", "Files", "f");
        add("copy", "Copy path", "c"); add("ai", "AI tools", "a");
    }
    return output;
}

function actionArgs(op, view, cfg, context) {
    var row = rawRow(view); context = context || {};
    op = {"docker-start":"start", "docker-stop":"stop", "docker-restart":"restart", "process-terminate":"terminate",
        "open-terminal":"terminal", "open-editor":"editor", "open-files":"files"}[op] || op;
    if (["start", "stop", "restart"].indexOf(op) >= 0) return /^[a-f0-9]{64}$/.test(row.id) ? ["docker-" + op, "--container-id=" + row.id] : null;
    if (op === "terminate") {
        if (!Number.isInteger(row.pid) || row.pid < 2 || row.pid > 4194304 || typeof row.startTicks !== "string" || !/^\d{1,20}$/.test(row.startTicks || "")
                || !Number.isInteger(row.port) || row.port < 1 || row.port > 65535) return null;
        return ["process-terminate", "--pid=" + row.pid, "--start-ticks=" + row.startTicks, "--port=" + row.port];
    }
    if (["terminal", "editor", "files", "launch-tool"].indexOf(op) < 0) return null;
    var path = context.path || row.path;
    var roots = lines(cfg.projectRoots);
    // The backend resolves symlinks and authorizes the canonical path against canonical roots.
    if (!validRoot(path) || !roots.length || !roots.every(validRoot)) return null;
    var args = [op === "launch-tool" ? op : "open-" + op, "--path=" + path];
    roots.forEach(function (root) { args.push("--project-root=" + root); });
    if (op === "launch-tool") {
        if (!/^[a-z0-9-]{1,40}$/.test(row.id)) return null;
        args.push("--tool=" + row.id);
    }
    if (op === "terminal" || op === "launch-tool") args.push("--terminal=" + cfg.terminal);
    if (op === "editor") args.push("--editor=" + cfg.editor);
    if (op === "launch-tool") {
        try { parseCustomTools(cfg.customTools); } catch (error) { return null; }
        customLines(cfg.customTools).forEach(function (line) { args.push("--custom-tool=" + line); });
    }
    return args;
}

function confirmText(op, view) {
    var row = rawRow(view);
    if (op === "terminate") return "Send SIGTERM to " + (row.process || "process") + " (PID " + row.pid + ") on port " + row.port + "? It will not be force-killed.";
    return (op === "restart" ? "Restart" : "Stop") + " container “" + row.name + "”?";
}

