import PJSIP

/// Write one line into pjsip's own log stream, with `swift-pjsua` as the sender.
///
/// Goes through `pj_log`, so the line gets pjsip's decoration and reaches every place pjsip's
/// own lines do — the console and ``PJSUA/Configuration/logSink`` — right next to the pjsua
/// lines it explains. The message travels as a `%s` argument, never as the format string.
func pjLog(_ level: Int32, _ message: String) {
    message.withCString { text in
        withVaList([text]) { pj_log("swift-pjsua", level, "%s", $0) }
    }
}
