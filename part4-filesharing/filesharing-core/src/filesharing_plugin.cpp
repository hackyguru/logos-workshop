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

// Part 4 implementation notes — the takeaways from integrating storage_module
// on Basecamp, distilled from vpavlin/logos-yolo's `docs/inter-module-comm.md`:
//
// 1. Vendor `storage_module_api.{h,cpp}` (under `vendor/`) instead of taking
//    logos-storage-module as a flake input. The upstream flake's
//    `logos-storage-nim?submodules=1` produces non-reproducible NAR hashes.
//
// 2. Use the typed `StorageModule` wrapper, not raw `invokeRemoteMethod`.
//    Events are only available via the typed `.on(...)` API, and the wrapper
//    decodes `LogosResult` returns cleanly (raw `invokeRemoteMethod` arrives
//    as an empty QVariant cross-process — a known serialization gap).
//
// 3. `storage_module.init()` + `start()` are synchronous calls that together
//    take ~30–80 s on cold start (libstorage discovery + libp2p bind).
//    Dispatch them via `QTimer::singleShot(0, this, [this](){ ... })` so the
//    QML click handler returns immediately — Qt's nested QEventLoop inside
//    the sync IPC keeps the UI responsive during the block.
//
// 4. QtRO is main-thread bound. Never call `invokeRemoteMethod` /
//    `*Async` from a worker thread — calls are silently dropped. The
//    singleShot above keeps us on the plugin's owner thread.
//
// 5. `.on()` handlers don't reliably fire cross-process in every Basecamp
//    build, so flip `m_storageStatus = 2` right after `start()` returns true
//    (yolo's "yolo-board pattern"). Subscribe to events anyway for
//    upload/download progress — when they DO fire, the state update is
//    correct; when they don't, we fall back to the direct return values.
//
// 6. Don't poll `manifests()` from a timer — serialize re-entrant sync IPC
//    calls through a dirty-flag + in-flight guard.

// ── helpers ──────────────────────────────────────────────────────────

namespace {

QString variantToJson(const QJsonObject& obj)
{
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

// Storage config. Bootstrap SPRs sourced from the published Codex devnet
// list at https://spr.codex.storage/devnet — without live peer seeds
// libstorage's discovery layer spins indefinitely looking for peers.
QString defaultStorageConfig()
{
    const QString dataRoot = QDir::cleanPath(
        QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
        + "/filesharing-storage");
    QDir().mkpath(dataRoot);

    QJsonArray bootstrap;
    bootstrap.append("spr:CiUIAhIhA-VlcoiRm02KyIzrcTP-ljFpzTljfBRRKTIvhMIwqBqWEgIDARpJCicAJQgCEiED5WVyiJGbTYrIjOtxM_6WMWnNOWN8FFEpMi-EwjCoGpYQs8n8wQYaCwoJBHTKubmRAnU6GgsKCQR0yrm5kQJ1OipHMEUCIQDwUNsfReB4ty7JFS5WVQ6n1fcko89qVAOfQEHixa03rgIgan2-uFNDT-r4s9TOkLe9YBkCbsRWYCHGGVJ25rLj0QE");
    bootstrap.append("spr:CiUIAhIhApIj9p6zJDRbw2NoCo-tj98Y760YbppRiEpGIE1yGaMzEgIDARpJCicAJQgCEiECkiP2nrMkNFvDY2gKj62P3xjvrRhumlGISkYgTXIZozMQvcz8wQYaCwoJBAWhF3WRAnVEGgsKCQQFoRd1kQJ1RCpGMEQCIFZB84O_nzPNuViqEGRL1vJTjHBJ-i5ZDgFL5XZxm4HAAiB8rbLHkUdFfWdiOmlencYVn0noSMRHzn4lJYoShuVzlw");
    bootstrap.append("spr:CiUIAhIhApqRgeWRPSXocTS9RFkQmwTZRG-Cdt7UR2N7POoz606ZEgIDARpJCicAJQgCEiECmpGB5ZE9JehxNL1EWRCbBNlEb4J23tRHY3s86jPrTpkQj8_8wQYaCwoJBAXfEfiRAnVOGgsKCQQF3xH4kQJ1TipGMEQCIGWJMsF57N1iIEQgTH7IrVOgEgv0J2P2v3jvQr5Cjy-RAiAy4aiZ8QtyDvCfl_K_w6SyZ9csFGkRNTpirq_M_QNgKw");

    QJsonObject cfg;
    cfg["data-dir"]       = dataRoot;
    cfg["bootstrap-node"] = bootstrap;
    cfg["log-level"]      = "INFO";
    cfg["log-file"]       = dataRoot + "/storage.log";
    return variantToJson(cfg);
}

} // namespace

// ── lifecycle ────────────────────────────────────────────────────────

FileSharingPlugin::FileSharingPlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "FileSharingPlugin: created";
}

FileSharingPlugin::~FileSharingPlugin()
{
    delete m_storage;
}

void FileSharingPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    // StorageModule's ctor is cheap — it just calls logosAPI->getClient().
    // The actual IPC (replica request + .on() subscriptions) happens on the
    // first `.on(...)` call, so we can construct eagerly.
    m_storage = new StorageModule(logosAPI);
    subscribeStorageEvents();
    qInfo() << "FileSharingPlugin: LogosAPI wired up, StorageModule ready";
}

// ── storage node start/stop ──────────────────────────────────────────

bool FileSharingPlugin::startStorage()
{
    if (m_storageStatus == 1 || m_storageStatus == 2) return true;

    // Reset transient state so a retry after an error starts clean.
    m_lastError.clear();
    m_manifestsCache.clear();
    m_manifestsDirty           = false;
    m_manifestsRefreshInFlight = false;
    m_upload   = UploadState{};
    m_download = DownloadState{};
    setStorageStatus(1);

    // Defer the blocking init+start off the click handler. QTimer::singleShot
    // schedules on `this`'s thread (the plugin's main thread) — exactly where
    // QtRO calls must originate from.
    QTimer::singleShot(0, this, [this]() { doInitAndStart(); });
    return true;
}

void FileSharingPlugin::doInitAndStart()
{
    if (!m_storage) {
        m_lastError = "StorageModule client not initialised (initLogos never ran?)";
        qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
        setStorageStatus(3);
        return;
    }

    const QString cfg = defaultStorageConfig();
    qInfo().noquote() << "FileSharingPlugin: storage.init cfg =" << cfg;

    const bool initOk = m_storage->init(cfg);
    qInfo() << "FileSharingPlugin: init() returned" << initOk;
    if (!initOk) {
        m_lastError = "storage_module.init() rejected the config";
        qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
        setStorageStatus(3);
        return;
    }

    const bool startOk = m_storage->start();
    qInfo() << "FileSharingPlugin: start() returned" << startOk;
    if (!startOk) {
        m_lastError = "storage_module.start() rejected";
        qWarning().noquote() << "FileSharingPlugin:" << m_lastError;
        setStorageStatus(3);
        return;
    }

    // Yolo pattern: flip ready now. The storageStart event (subscribed in
    // subscribeStorageEvents) arrives when libstorage's boot completes, and
    // our handler is a no-op if status is already 2.
    qInfo() << "FileSharingPlugin: storage_module READY";
    m_lastError.clear();
    m_manifestsDirty = true;
    setStorageStatus(2);
}

bool FileSharingPlugin::stopStorage()
{
    if (m_storageStatus == 0 || !m_storage) return true;

    // Fire and forget — our local status flips immediately. The real stop
    // completes in the background and we don't block on its reply.
    m_storage->stopAsync([](LogosResult) { /* ignore */ });
    setStorageStatus(0);
    return true;
}

int     FileSharingPlugin::storageStatus() { return m_storageStatus; }
QString FileSharingPlugin::lastError()     { return m_lastError; }

// ── upload ───────────────────────────────────────────────────────────

QString FileSharingPlugin::uploadFile(const QString& fileUrl)
{
    if (m_storageStatus != 2 || !m_storage) {
        qWarning() << "FileSharingPlugin: uploadFile called while storage not running";
        return QString();
    }
    if (fileUrl.isEmpty()) return QString();

    // One upload at a time — libstorage reuses session IDs across uploads,
    // so interleaved uploads cross their progress/done events.
    if (m_upload.status == 1) {
        qWarning() << "FileSharingPlugin: upload already in flight, ignoring";
        return QString();
    }

    const QUrl url(fileUrl);

    m_upload          = UploadState{};
    m_upload.filename = url.isLocalFile()
        ? QFileInfo(url.toLocalFile()).fileName()
        : url.fileName();
    m_upload.status   = 1;

    qInfo().noquote() << "FileSharingPlugin: uploading" << m_upload.filename;
    const LogosResult r = m_storage->uploadUrl(QVariant::fromValue(url), 64 * 1024);
    if (!r.success) {
        m_upload.status = 3;
        m_upload.error  = r.error.toString();
        qWarning().noquote() << "FileSharingPlugin: uploadUrl failed:" << m_upload.error;
        return QString();
    }

    m_upload.sessionId = r.value.toString();
    qInfo() << "FileSharingPlugin: upload session" << m_upload.sessionId
            << "opened for" << m_upload.filename;
    return m_upload.sessionId;
}

// ── download ─────────────────────────────────────────────────────────

bool FileSharingPlugin::downloadFile(const QString& cid, const QString& destUrl)
{
    if (m_storageStatus != 2 || !m_storage) {
        qWarning() << "FileSharingPlugin: downloadFile called while storage not running";
        return false;
    }
    if (cid.isEmpty() || destUrl.isEmpty()) return false;

    const QUrl url(destUrl);

    m_download          = DownloadState{};
    m_download.cid      = cid;
    m_download.destPath = url.isLocalFile() ? url.toLocalFile() : destUrl;
    m_download.status   = 1;

    qInfo().noquote() << "FileSharingPlugin: downloading" << cid << "->" << m_download.destPath;
    const LogosResult r = m_storage->downloadToUrl(cid, url, /*local=*/false, 64 * 1024);
    if (!r.success) {
        m_download.status = 3;
        m_download.error  = r.error.toString();
        qWarning().noquote() << "FileSharingPlugin: downloadToUrl failed:" << m_download.error;
        return false;
    }
    return true;
}

// ── remove ───────────────────────────────────────────────────────────

bool FileSharingPlugin::removeFile(const QString& cid)
{
    if (m_storageStatus != 2 || !m_storage || cid.isEmpty()) return false;

    const LogosResult r = m_storage->remove(cid);
    if (!r.success) {
        qWarning().noquote() << "FileSharingPlugin: remove failed:" << r.error.toString();
        return false;
    }
    emit eventResponse("fileRemoved", QVariantList{ cid });
    m_manifestsDirty = true;
    return true;
}

// ── JSON views ───────────────────────────────────────────────────────

QString FileSharingPlugin::listFiles()
{
    auto emitCache = [this]() {
        return m_manifestsCache.isEmpty() ? QStringLiteral("[]") : m_manifestsCache;
    };
    if (m_storageStatus != 2 || !m_storage) return emitCache();
    if (m_manifestsRefreshInFlight) return emitCache();
    if (!m_manifestsCache.isEmpty() && !m_manifestsDirty) return emitCache();

    m_manifestsRefreshInFlight = true;
    m_manifestsDirty           = false;
    m_storage->manifestsAsync([this](LogosResult res) {
        m_manifestsRefreshInFlight = false;
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
    return emitCache();
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

void FileSharingPlugin::subscribeStorageEvents()
{
    if (!m_storage || m_storageEventsBound) return;
    m_storageEventsBound = true;

    // storageStart — [bool ok, QString msg]. Yolo flips ready after start()
    // returns directly because events don't always reach us; we do too, so
    // this handler is just belt-and-braces.
    m_storage->on("storageStart", [this](const QVariantList& d) {
        const bool ok = !d.isEmpty() && d[0].toBool();
        qInfo() << "FileSharingPlugin: EVT storageStart ok=" << ok;
        if (ok && m_storageStatus != 2) setStorageStatus(2);
    });

    // storageStop — [bool ok, QString msg]
    m_storage->on("storageStop", [this](const QVariantList& d) {
        const bool ok = !d.isEmpty() && d[0].toBool();
        qInfo() << "FileSharingPlugin: EVT storageStop ok=" << ok;
        setStorageStatus(0);
    });

    // storageUploadProgress — [bool ok, QString sessionId, qint64 bytes]
    m_storage->on("storageUploadProgress", [this](const QVariantList& d) {
        if (d.size() < 3) return;
        const bool    ok  = d[0].toBool();
        const QString sid = d[1].toString();
        if (!ok || sid != m_upload.sessionId) return;
        m_upload.bytes += d[2].toLongLong();
        emit eventResponse("uploadProgress", QVariantList{ sid, m_upload.bytes });
    });

    // storageUploadDone — payload layout varies by storage_module build:
    //   [bool ok, QString sessionId, QString cid]  (most common upstream)
    //   [bool ok, QString cid]                     (older builds)
    //   [int sessionId, QString manifestCid, QString treeCid]  (vpavlin fork)
    // Plus on macOS, since the uploadUrl return value is empty (yolo-doc'd
    // serialization bug), we may not even know the real sessionId. We claim
    // ANY in-flight upload done event as ours when status == 1.
    m_storage->on("storageUploadDone", [this](const QVariantList& d) {
        if (d.isEmpty() || m_upload.status != 1) return;

        bool ok = true;
        QString sid, cid, err;

        // Sniff layout: if data[0] is bool, it's one of the upstream shapes.
        // If data[0] is an int/string, it's the vpavlin [sessionId, cid, ...] shape.
        if (d[0].typeId() == QMetaType::Bool) {
            ok = d[0].toBool();
            const QString second = d.value(1).toString();
            const QString third  = d.value(2).toString();
            if (!third.isEmpty()) { sid = second; cid = third; }
            else if (ok)          { cid = second; }
            else                  { err = second; }
        } else {
            sid = d[0].toString();
            cid = d.value(1).toString();
            ok  = !cid.isEmpty();
        }

        if (ok) {
            m_upload.cid     = cid;
            m_upload.status  = 2;
            if (!sid.isEmpty()) m_upload.sessionId = sid;
            m_manifestsDirty = true;
            qInfo() << "FileSharingPlugin: upload done — CID" << cid;
            emit eventResponse("uploadDone", QVariantList{ m_upload.sessionId, cid });
        } else {
            m_upload.error  = err;
            m_upload.status = 3;
            emit eventResponse("uploadError", QVariantList{ m_upload.sessionId, err });
        }
    });

    // storageDownloadProgress — [bool ok, QString sessionId, qint64 bytes]
    m_storage->on("storageDownloadProgress", [this](const QVariantList& d) {
        if (d.size() < 3) return;
        const bool    ok  = d[0].toBool();
        const QString sid = d[1].toString();
        if (!ok || sid != m_download.cid) return;
        m_download.bytes += d[2].toLongLong();
        emit eventResponse("downloadProgress", QVariantList{ sid, m_download.bytes });
    });

    // storageDownloadDone — [bool ok, QString sessionId, QString msg]
    m_storage->on("storageDownloadDone", [this](const QVariantList& d) {
        if (d.isEmpty()) return;
        const bool    ok  = d[0].toBool();
        const QString sid = d.value(1).toString();
        if (sid != m_download.cid) return;
        if (ok) {
            m_download.status = 2;
            emit eventResponse("downloadDone", QVariantList{ sid, m_download.destPath });
        } else {
            m_download.error  = d.value(2).toString();
            m_download.status = 3;
            emit eventResponse("downloadError", QVariantList{ sid, m_download.error });
        }
    });
}

void FileSharingPlugin::setStorageStatus(int status)
{
    if (m_storageStatus == status) return;
    m_storageStatus = status;
    emit eventResponse("storageStatusChanged", QVariantList{ status });
}
