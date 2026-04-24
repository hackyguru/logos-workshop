#include "filesharing_plugin.h"

#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

// ── helpers ──────────────────────────────────────────────────────────

namespace {

QString variantToJson(const QJsonObject& obj)
{
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

LogosResult toLogosResult(const QVariant& v)
{
    if (v.canConvert<LogosResult>()) return v.value<LogosResult>();
    // Some methods (init, start) return bool — synthesise a LogosResult for a
    // uniform call-site.
    LogosResult r;
    r.success = v.toBool();
    if (!r.success) r.error = QStringLiteral("RPC returned false");
    return r;
}

// The JSON config we pass to storage_module.init.
//
// Observed on Mac with the current upstream build: init() blocks for minutes
// in libstorage's discovery layer when no bootstrap peers are configured but
// discovery is still enabled — discv5 keeps looking for peers that don't
// exist. We pin `data-dir` + an empty bootstrap-node list so libstorage
// starts in local-only mode. Good enough for workshop uploads (the CID is
// content-addressable and still shareable; we just don't auto-join any
// swarm), and unblocks init().
QString defaultStorageConfig()
{
    const QString dataRoot = QDir::cleanPath(
        QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
        + "/filesharing-storage");
    QDir().mkpath(dataRoot);

    QJsonObject cfg;
    cfg["data-dir"]       = dataRoot;
    cfg["bootstrap-node"] = QJsonArray();   // empty — no peers to chase
    cfg["log-level"]      = "INFO";
    return variantToJson(cfg);
}

} // namespace

// ── lifecycle ────────────────────────────────────────────────────────

FileSharingPlugin::FileSharingPlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "FileSharingPlugin: created";
}

FileSharingPlugin::~FileSharingPlugin() = default;

void FileSharingPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    qDebug() << "FileSharingPlugin: LogosAPI wired up";
}

// ── storage node start/stop ──────────────────────────────────────────

bool FileSharingPlugin::startStorage()
{
    if (m_storageStatus == 1 || m_storageStatus == 2) return true;

    // Wipe the data-dir before start. libstorage (Nim) crashes with a
    // nil-deref in `node_lifecycle_request` → `storage.start` if the on-disk
    // state was left dirty by a previous unclean shutdown — a common outcome
    // during workshop iteration (force-quit, Basecamp restart mid-init, etc.).
    // A fresh dir gives the node a clean slate. Tradeoff: the local file list
    // resets between sessions, but CIDs from earlier uploads remain valid and
    // downloadable since they're content-addressable over the network.
    const QString dataRoot = QDir::cleanPath(
        QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
        + "/filesharing-storage");
    if (QDir(dataRoot).exists()) {
        qInfo().noquote() << "FileSharingPlugin: wiping stale data-dir" << dataRoot;
        QDir(dataRoot).removeRecursively();
    }

    // storage_module.init() + start() take ~40 s on a cold boot. Use the
    // async invokeRemoteMethodAsync chain (doInitAndStart → asyncStart) so
    // the main thread stays responsive during the whole sequence.
    setStorageStatus(1);   // "starting" — UI shows amber dot immediately
    m_lastError.clear();
    m_manifestsCache.clear();
    m_manifestsDirty           = false;
    m_manifestsRefreshInFlight = false;
    m_upload   = UploadState{};
    m_download = DownloadState{};

    QTimer::singleShot(0, this, [this]() { doInitAndStart(); });
    return true;
}

void FileSharingPlugin::doInitAndStart()
{
    if (!m_storageClient) {
        m_storageClient = logosAPI->getClient("storage_module");
        if (!m_storageClient) {
            m_lastError = "storage_module client unavailable (is the module installed?)";
            qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
            setStorageStatus(3);
            return;
        }
    }

    if (!m_storageObject) {
        m_storageObject = m_storageClient->requestObject("storage_module");
        if (!m_storageObject) {
            m_lastError = "storage_module object unavailable";
            qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
            setStorageStatus(3);
            return;
        }
        wireEvents();
    }

    // Async chain: initAsync → startAsync → mark ready. The synchronous
    // invokeRemoteMethod calls blocked the main thread for ~40 s on cold
    // start (libstorage discovery + libp2p transport bind), causing
    // Basecamp to hang and crash on shutdown. invokeRemoteMethodAsync
    // returns immediately and calls us back when the remote method settles,
    // so the UI stays responsive during the whole boot sequence.
    const QString cfg = defaultStorageConfig();
    qInfo().noquote() << "FileSharingPlugin: storage_module.init cfg =" << cfg;

    // The default SDK timeout is 20 s (Timeout(20000)). init() is fast, but
    // we pass 120 s anyway to match start() — doesn't hurt. Passing the
    // timeout explicitly requires the (name, method, QVariantList, cb, Timeout)
    // overload.
    m_storageClient->invokeRemoteMethodAsync(
        "storage_module", "init", QVariantList{ cfg },
        [this](QVariant v) {
            const bool initOk = v.isValid() && v.toBool();
            qInfo() << "FileSharingPlugin: init() returned" << initOk
                    << (initOk ? "" : "— will try start() anyway");
            if (initOk) m_initialised = true;
            // Proceed to start() regardless — init returns false when the
            // node is already initialised (e.g. after a crash recovery),
            // but start() may still succeed.
            this->asyncStart();
        },
        Timeout(120000));
}

void FileSharingPlugin::asyncStart()
{
    if (!m_storageClient) return;

    // start() can block for 30–40 s inside libstorage (libp2p discovery +
    // transport bind). The default SDK timeout is 20 s — without an
    // explicit override the callback fires with an invalid QVariant after
    // 20 s, we misread that as a failure, retry, loop forever. Pass
    // 120 s so the real reply has time to come back.
    m_storageClient->invokeRemoteMethodAsync(
        "storage_module", "start", QVariantList(),
        [this](QVariant v) {
            const bool startOk = v.isValid() && v.toBool();
            qInfo() << "FileSharingPlugin: start() returned" << startOk
                    << (v.isValid() ? "" : "(TIMEOUT — raise Timeout value)");

            if (!startOk) {
                // Retry up to 5 times with 3 s backoff — libstorage
                // sometimes needs a moment after a crash-recovery.
                if (m_initRetryCount < 5) {
                    ++m_initRetryCount;
                    qWarning() << "FileSharingPlugin: start() failed, retry"
                               << m_initRetryCount << "/5 in 3 s";
                    QTimer::singleShot(3000, this,
                        [this]() { doInitAndStart(); });
                    return;
                }
                m_lastError = "storage_module refused start after " +
                              QString::number(m_initRetryCount) + " retries";
                qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
                m_initRetryCount = 0;
                setStorageStatus(3);
                return;
            }

            // Mark ready directly — per stash's notes the storageStart
            // event doesn't always arrive reliably cross-process via QRO.
            m_initRetryCount = 0;
            m_lastError.clear();
            qInfo() << "FileSharingPlugin: storage_module READY";
            setStorageStatus(2);
        },
        Timeout(120000));
}

bool FileSharingPlugin::stopStorage()
{
    if (m_storageStatus == 0) return true;
    if (!m_storageClient) { setStorageStatus(0); return true; }

    // Fire-and-forget async stop. We flip the local status immediately so
    // the UI reflects the intent — the actual stop completes in the
    // background and we don't care about the return value.
    m_storageClient->invokeRemoteMethodAsync(
        "storage_module", "stop", QVariantList(),
        [](QVariant) { /* ignore result */ });
    setStorageStatus(0);
    return true;
}

int     FileSharingPlugin::storageStatus() { return m_storageStatus; }
QString FileSharingPlugin::lastError()     { return m_lastError; }

// ── upload ───────────────────────────────────────────────────────────

QString FileSharingPlugin::uploadFile(const QString& fileUrl)
{
    if (m_storageStatus != 2) {
        qWarning() << "FileSharingPlugin: uploadFile called while storage not running";
        return QString();
    }
    if (fileUrl.isEmpty()) return QString();

    // Guard against concurrent uploads. libstorage reuses session IDs (per
    // stash halt.md, the first upload gets session 0, and subsequent ones
    // may collide), which means interleaved uploads can cross their
    // progress / done events. One at a time.
    if (m_upload.status == 1) {
        qWarning() << "FileSharingPlugin: upload already in progress, ignoring";
        return QString();
    }

    const QUrl url(fileUrl);

    // Reset the single upload slot so the UI sees fresh progress immediately.
    m_upload          = UploadState{};
    m_upload.filename = url.isLocalFile()
        ? QFileInfo(url.toLocalFile()).fileName()
        : url.fileName();
    m_upload.status   = 1;

    // Async dispatch — the sync variant can hang the main thread when
    // storage_module is busy processing a prior upload's tail events. The
    // session ID arrives via callback; until then the UI shows the
    // indeterminate progress bar.
    const int kChunk = 64 * 1024;
    qInfo().noquote() << "FileSharingPlugin: uploadUrl dispatched for" << m_upload.filename;
    m_storageClient->invokeRemoteMethodAsync(
        "storage_module", "uploadUrl",
        QVariantList{ url, kChunk },
        [this](QVariant v) {
            const LogosResult res = toLogosResult(v);
            if (!res.success) {
                m_upload.status = 3;
                m_upload.error  = res.error.toString();
                qWarning().noquote() << "FileSharingPlugin: uploadUrl failed:" << m_upload.error;
                return;
            }
            m_upload.sessionId = res.value.toString();
            qInfo() << "FileSharingPlugin: upload session" << m_upload.sessionId
                    << "opened for" << m_upload.filename;
        },
        Timeout(60000));

    // Return empty — UI polls currentUpload() for state instead of using
    // a session ID we haven't got yet.
    return QString();
}

// ── download ─────────────────────────────────────────────────────────

bool FileSharingPlugin::downloadFile(const QString& cid, const QString& destUrl)
{
    if (m_storageStatus != 2) {
        qWarning() << "FileSharingPlugin: downloadFile called while storage not running";
        return false;
    }
    if (cid.isEmpty() || destUrl.isEmpty()) return false;

    const QUrl url(destUrl);

    m_download           = DownloadState{};
    m_download.cid       = cid;
    m_download.destPath  = url.isLocalFile() ? url.toLocalFile() : destUrl;
    m_download.status    = 1;

    const bool kLocal = false;
    const int  kChunk = 64 * 1024;
    qInfo().noquote() << "FileSharingPlugin: downloadToUrl dispatched for cid" << cid;
    m_storageClient->invokeRemoteMethodAsync(
        "storage_module", "downloadToUrl",
        QVariantList{ cid, url, kLocal, kChunk },
        [this](QVariant v) {
            const LogosResult res = toLogosResult(v);
            if (!res.success) {
                m_download.status = 3;
                m_download.error  = res.error.toString();
                qWarning().noquote() << "FileSharingPlugin: downloadToUrl failed:" << m_download.error;
            }
        },
        Timeout(60000));
    return true;
}

// ── remove ───────────────────────────────────────────────────────────

bool FileSharingPlugin::removeFile(const QString& cid)
{
    if (m_storageStatus != 2 || cid.isEmpty()) return false;
    m_storageClient->invokeRemoteMethodAsync(
        "storage_module", "remove", cid,
        [this, cid](QVariant v) {
            const LogosResult res = toLogosResult(v);
            if (!res.success) {
                qWarning().noquote() << "FileSharingPlugin: remove failed:" << res.error.toString();
                return;
            }
            emit eventResponse("fileRemoved", QVariantList{ cid });
            // Nudge the next manifests() refresh to skip the just-removed row.
            m_manifestsDirty = true;
        });
    return true;
}

// ── JSON views ───────────────────────────────────────────────────────

QString FileSharingPlugin::listFiles()
{
    // Polled by QML every 500 ms–1.5 s. We return the cached JSON string
    // synchronously (instant) and kick off an async refresh in the
    // background. A sync invokeRemoteMethod here would block the main thread
    // on every tick, which is exactly the class of hang we've been fixing.
    if (m_storageStatus == 2 && m_storageClient &&
        (m_manifestsDirty || !m_manifestsRefreshInFlight)) {
        m_manifestsRefreshInFlight = true;
        m_manifestsDirty           = false;
        m_storageClient->invokeRemoteMethodAsync(
            "storage_module", "manifests", QVariantList(),
            [this](QVariant v) {
                m_manifestsRefreshInFlight = false;
                const LogosResult res = toLogosResult(v);
                if (!res.success) {
                    qWarning().noquote() << "FileSharingPlugin: manifests failed:"
                                         << res.error.toString();
                    return;
                }
                QJsonArray arr;
                const QVariantList items = res.value.toList();
                for (const QVariant& item : items) {
                    const QVariantMap m = item.toMap();
                    QJsonObject o;
                    o["cid"]         = m.value("cid").toString();
                    o["filename"]    = m.value("filename").toString();
                    o["mimetype"]    = m.value("mimetype").toString();
                    o["datasetSize"] = QJsonValue::fromVariant(m.value("datasetSize"));
                    arr.append(o);
                }
                m_manifestsCache = QString::fromUtf8(
                    QJsonDocument(arr).toJson(QJsonDocument::Compact));
            });
    }
    return m_manifestsCache.isEmpty() ? QStringLiteral("[]") : m_manifestsCache;
}

QString FileSharingPlugin::currentUpload()
{
    QJsonObject o;
    o["sessionId"] = m_upload.sessionId;
    o["filename"]  = m_upload.filename;
    o["bytes"]     = QJsonValue::fromVariant(QVariant::fromValue(m_upload.bytes));
    o["cid"]       = m_upload.cid;
    o["error"]     = m_upload.error;
    o["status"]    = m_upload.status;
    return variantToJson(o);
}

QString FileSharingPlugin::currentDownload()
{
    QJsonObject o;
    o["cid"]      = m_download.cid;
    o["destPath"] = m_download.destPath;
    o["bytes"]    = QJsonValue::fromVariant(QVariant::fromValue(m_download.bytes));
    o["error"]    = m_download.error;
    o["status"]   = m_download.status;
    return variantToJson(o);
}

// ── event wiring ─────────────────────────────────────────────────────

void FileSharingPlugin::wireEvents()
{
    if (!m_storageObject || !m_storageClient) return;

    m_storageClient->onEvent(m_storageObject, "storageStart",
        [this](const QString&, const QVariantList& data) { handleStorageStart(data); });

    m_storageClient->onEvent(m_storageObject, "storageStop",
        [this](const QString&, const QVariantList& data) { handleStorageStop(data); });

    m_storageClient->onEvent(m_storageObject, "storageUploadProgress",
        [this](const QString&, const QVariantList& data) { handleUploadProgress(data); });

    m_storageClient->onEvent(m_storageObject, "storageUploadDone",
        [this](const QString&, const QVariantList& data) { handleUploadDone(data); });

    m_storageClient->onEvent(m_storageObject, "storageDownloadProgress",
        [this](const QString&, const QVariantList& data) { handleDownloadProgress(data); });

    m_storageClient->onEvent(m_storageObject, "storageDownloadDone",
        [this](const QString&, const QVariantList& data) { handleDownloadDone(data); });
}

void FileSharingPlugin::handleStorageStart(const QVariantList& data)
{
    const bool ok = data.value(0).toBool();
    if (ok) {
        m_lastError.clear();
        setStorageStatus(2);
    } else {
        m_lastError = "storageStart: " + data.value(1).toString();
        qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
        setStorageStatus(3);
    }
}

void FileSharingPlugin::handleStorageStop(const QVariantList& data)
{
    Q_UNUSED(data);
    setStorageStatus(0);
}

void FileSharingPlugin::handleUploadProgress(const QVariantList& data)
{
    if (data.size() < 3) return;
    const bool    ok  = data[0].toBool();
    const QString sid = data[1].toString();
    if (sid != m_upload.sessionId) return;   // not our session
    if (!ok) {
        m_upload.status = 3;
        m_upload.error  = data[2].toString();
        emit eventResponse("uploadError", QVariantList{ sid, m_upload.error });
        return;
    }
    // data[2] is a per-chunk byte count; accumulate.
    m_upload.bytes += data[2].toLongLong();
    emit eventResponse("uploadProgress", QVariantList{ sid, m_upload.bytes });
}

void FileSharingPlugin::handleUploadDone(const QVariantList& data)
{
    // Payload format varies across storage_module builds — per the xAlisher
    // stash halt.md, newer builds emit [sessionId(int), manifestCid, treeCid]
    // with no leading success flag, while older builds emit
    // [success(bool), sessionId, cid]. Sniff the type of data[0] to decide.
    if (data.isEmpty()) return;

    bool    ok  = true;
    QString sid;
    QString cid;
    QString err;

    if (data[0].typeId() == QMetaType::Bool) {
        // Old layout: [ok, sessionId, cid-or-error]
        ok  = data[0].toBool();
        sid = data.value(1).toString();
        if (ok)  cid = data.value(2).toString();
        else     err = data.value(2).toString();
    } else {
        // New layout: [sessionId, manifestCid, treeCid]
        sid = data[0].toString();
        cid = data.value(1).toString();
        ok  = !cid.isEmpty();
        if (!ok) err = "storage_module returned empty cid";
    }

    if (sid != m_upload.sessionId) return;

    if (ok) {
        m_upload.cid    = cid;
        m_upload.status = 2;
        m_manifestsDirty = true;  // nudge listFiles to refresh promptly
        qDebug() << "FileSharingPlugin: upload done — CID" << cid;
        emit eventResponse("uploadDone", QVariantList{ sid, cid });
    } else {
        m_upload.error  = err;
        m_upload.status = 3;
        emit eventResponse("uploadError", QVariantList{ sid, err });
    }
}

void FileSharingPlugin::handleDownloadProgress(const QVariantList& data)
{
    if (data.size() < 3) return;
    const bool    ok  = data[0].toBool();
    const QString sid = data[1].toString();
    if (sid != m_download.cid) return;
    if (!ok) {
        m_download.status = 3;
        m_download.error  = data[2].toString();
        emit eventResponse("downloadError", QVariantList{ sid, m_download.error });
        return;
    }
    m_download.bytes += data[2].toLongLong();
    emit eventResponse("downloadProgress", QVariantList{ sid, m_download.bytes });
}

void FileSharingPlugin::handleDownloadDone(const QVariantList& data)
{
    if (data.size() < 3) return;
    const bool    ok  = data[0].toBool();
    const QString sid = data[1].toString();
    if (sid != m_download.cid) return;
    if (ok) {
        m_download.status = 2;
        emit eventResponse("downloadDone", QVariantList{ sid, m_download.destPath });
    } else {
        m_download.status = 3;
        m_download.error  = data[2].toString();
        emit eventResponse("downloadError", QVariantList{ sid, m_download.error });
    }
}

void FileSharingPlugin::setStorageStatus(int status)
{
    if (m_storageStatus == status) return;
    m_storageStatus = status;
    emit eventResponse("storageStatusChanged", QVariantList{ status });
}
