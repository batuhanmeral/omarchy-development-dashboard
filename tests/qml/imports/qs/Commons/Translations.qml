import QtQuick

QtObject {
    id: root
    property url directory
    readonly property string language: I18n.language
    readonly property var english: readCatalog("en")
    readonly property var strings: language === "en" ? english : Object.assign({}, english, readCatalog(language))

    function readCatalog(locale) {
        if (!String(directory))
            return {};
        const request = new XMLHttpRequest();
        request.open("GET", String(directory) + "/" + locale + ".json", false);
        request.send();
        return request.responseText ? JSON.parse(request.responseText) : {};
    }

    function t(key, fallback) {
        const value = strings[key];
        return typeof value === "string" ? value : value ? value.other : fallback || key;
    }

    function tn(key, count, fallback) {
        const value = strings[key];
        if (!value || typeof value === "string")
            return value || fallback || key;
        return language === "en" && count === 1 ? value.one : value.other;
    }
}
