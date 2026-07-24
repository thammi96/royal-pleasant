/* ============================================================================
 *  discover-webclient-api.js
 *  Zweck: Die internen API-Aufrufe des Pleasant WebClients mitschneiden,
 *  OHNE vertrauliche Werte preiszugeben. Es werden nur Methode, URL,
 *  Parameter-/Feld-NAMEN und die STRUKTUR der Antworten erfasst; alle
 *  String-Werte werden durch "str(<Laenge>)" ersetzt, Zahlen durch "num".
 *
 *  Anwendung:
 *   1. Im normalen Browser (Edge/Chrome) https://<server>/WebClient/Main
 *      oeffnen und per SSO anmelden.
 *   2. F12 -> Reiter "Console".
 *   3. Diesen kompletten Text einfuegen und Enter druecken.
 *   4. Im WebClient: einen Ordner mit Eintraegen aufklappen und bei EINEM
 *      Eintrag das Passwort anzeigen/kopieren.
 *   5. In der Console  __dumpApi()  eingeben und Enter.
 *   6. Die Ausgabe (rechtsklick -> "Copy") an den Entwickler geben.
 *      -> Enthaelt KEINE Passwoerter, Tokens oder Cookies, nur Struktur.
 * ========================================================================== */
(function () {
    if (window.__apiLog) { console.log('[discover] bereits aktiv'); return; }
    window.__apiLog = [];

    // Wert -> Struktur (rekursiv), ohne echte Inhalte
    function shape(v, depth) {
        depth = depth || 0;
        if (depth > 6) return '...';
        if (v === null) return null;
        if (typeof v === 'string') return 'str(' + v.length + ')';
        if (typeof v === 'number') return 'num';
        if (typeof v === 'boolean') return v; // bool ist unkritisch
        if (Array.isArray(v)) return v.length ? [shape(v[0], depth + 1), '(' + v.length + ' items)'] : [];
        if (typeof v === 'object') {
            var o = {};
            for (var k in v) { if (Object.prototype.hasOwnProperty.call(v, k)) o[k] = shape(v[k], depth + 1); }
            return o;
        }
        return typeof v;
    }

    function bodyShape(body) {
        if (!body) return null;
        if (typeof body === 'string') {
            // JSON?
            try { return shape(JSON.parse(body)); } catch (e) {}
            // form-urlencoded -> nur Feldnamen
            if (body.indexOf('=') > -1) {
                return body.split('&').map(function (p) { return p.split('=')[0]; });
            }
            return 'str(' + body.length + ')';
        }
        try { return shape(body); } catch (e) { return 'unknown'; }
    }

    function record(method, url, reqBody, respText) {
        var resp;
        try { resp = shape(JSON.parse(respText)); }
        catch (e) { resp = respText ? ('non-json(' + respText.length + ')') : null; }
        // nur die Pfadkomponente + Query-NAMEN behalten, keine Query-Werte
        var u = url;
        try {
            var a = document.createElement('a'); a.href = url;
            var qn = a.search ? a.search.substring(1).split('&').map(function (p) { return p.split('=')[0]; }) : [];
            u = a.pathname + (qn.length ? ('?' + qn.join('&')) : '');
        } catch (e) {}
        window.__apiLog.push({ method: method, url: u, req: bodyShape(reqBody), resp: resp });
    }

    // fetch patchen
    var origFetch = window.fetch;
    if (origFetch) {
        window.fetch = function (input, init) {
            var url = (typeof input === 'string') ? input : (input && input.url);
            var method = (init && init.method) || (input && input.method) || 'GET';
            var reqBody = init && init.body;
            return origFetch.apply(this, arguments).then(function (resp) {
                try {
                    resp.clone().text().then(function (t) { record(method, url, reqBody, t); }).catch(function () {});
                } catch (e) {}
                return resp;
            });
        };
    }

    // XMLHttpRequest patchen
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
        this.__m = method; this.__u = url; return origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function (body) {
        var self = this;
        this.addEventListener('load', function () {
            try { record(self.__m, self.__u, body, self.responseText); } catch (e) {}
        });
        return origSend.apply(this, arguments);
    };

    window.__dumpApi = function () {
        // nur eindeutige Endpunkte, aber mit einem Beispiel-Shape je Endpunkt
        var seen = {}, out = [];
        window.__apiLog.forEach(function (e) {
            var key = e.method + ' ' + e.url;
            if (seen[key]) return; seen[key] = true;
            out.push(e);
        });
        var text = '===== WEBCLIENT API DISCOVERY (nur Struktur, keine Werte) =====\n'
                 + JSON.stringify(out, null, 2);
        console.log(text);
        return text;
    };

    console.log('[discover] aktiv. Jetzt Ordner aufklappen + 1 Passwort anzeigen, dann __dumpApi() ausfuehren.');
})();
