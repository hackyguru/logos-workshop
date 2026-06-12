#include "lotion_plugin.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QRandomGenerator>
#include <QSet>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUrl>
#include <QUuid>

#include <openssl/evp.h>

// Part 7 — private publishing.
//
// Three concerns, all kept on the C++ side because they don't touch
// storage_module IPC (which hangs from C++ on macOS — see
// lotion_interface.h):
//
//   1. Envelope format. JSON of one of two shapes:
//        public:   {"v":1,"private":false,"title":"...","body":"..."}
//        private:  {"v":1,"private":true,"kdf":"PBKDF2-HMAC-SHA256",
//                   "iter":200000,"salt":"<b64>","nonce":"<b64>",
//                   "tag":"<b64>","ciphertext":"<b64>"}
//      Private envelopes encrypt an inner {"title":"...","body":"..."} JSON
//      so the title is also hidden until decrypt.
//
//   2. Crypto. AES-256-GCM, key from PBKDF2-HMAC-SHA256 (200k iter,
//      16-byte random salt, 12-byte random nonce, 16-byte tag).
//
//   3. SQLite history. Same "named connection under AppDataLocation"
//      pattern as part 2's todo plugin.
//
// Storage (init/start/uploadUrl/downloadToUrl) happens in publishing-ui's
// QML — Main.qml talks to storage_module via the logos JS bridge.

static constexpr char SQL_CONNECTION[] = "logos-workshop-lotion";

namespace {

QString jsonString(const QJsonObject& obj)
{
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

QByteArray randomBytes(int n)
{
    QByteArray out(n, Qt::Uninitialized);
    // QRandomGenerator::system() is the OS CSPRNG (getentropy / BCryptGenRandom).
    auto* gen = QRandomGenerator::system();
    const int words = n / 4;
    if (words > 0)
        gen->fillRange(reinterpret_cast<quint32*>(out.data()), words);
    // Tail bytes (n % 4).
    if (n % 4) {
        const quint32 extra = gen->generate();
        for (int i = 0; i < n % 4; ++i)
            out[words * 4 + i] = static_cast<char>((extra >> (i * 8)) & 0xff);
    }
    return out;
}

QString cacheDir()
{
    const QString d = QDir::cleanPath(
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
        + "/lotion");
    QDir().mkpath(d);
    return d;
}

bool parseBoolish(const QString& s)
{
    // QML hands us bools as strings via the prerelease IPC's QString-coerce
    // arg path, so accept both "true"/"1"/"yes" and the literal.
    const QString t = s.trimmed().toLower();
    return t == "true" || t == "1" || t == "yes";
}

} // namespace

// ── lifecycle ────────────────────────────────────────────────────────

LotionPlugin::LotionPlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "LotionPlugin: created";
}

LotionPlugin::~LotionPlugin()
{
    if (QSqlDatabase::contains(SQL_CONNECTION)) {
        {
            QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
            if (db.isOpen()) db.close();
        }
        QSqlDatabase::removeDatabase(SQL_CONNECTION);
    }
}

void LotionPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    if (!openDatabase()) {
        qWarning() << "LotionPlugin: SQLite open failed — history won't persist";
    }
    qInfo() << "LotionPlugin: ready (storage I/O happens in the QML UI)";
}

// ── envelope build + temp file ───────────────────────────────────────

QString LotionPlugin::prepareEnvelopeFile(const QString& title,
                                              const QString& body,
                                              const QString& password,
                                              const QString& metaJson)
{
    if (title.trimmed().isEmpty() || body.isEmpty()) {
        qWarning() << "LotionPlugin::prepareEnvelopeFile: title or body empty";
        return {};
    }
    // Parse the UI's meta blob. Bad/empty JSON is non-fatal — we just
    // publish without extras (back-compat with older clients).
    QJsonObject metaObj;
    if (!metaJson.isEmpty()) {
        QJsonParseError perr{};
        const QJsonDocument doc = QJsonDocument::fromJson(metaJson.toUtf8(), &perr);
        if (perr.error == QJsonParseError::NoError && doc.isObject()) {
            metaObj = doc.object();
        } else {
            qWarning().noquote() << "LotionPlugin: ignoring malformed metaJson:"
                                 << perr.errorString();
        }
    }
    QString err;
    const QByteArray env = buildEnvelope(title, body, password, metaObj, &err);
    if (env.isEmpty()) {
        qWarning().noquote() << "LotionPlugin: envelope build failed:" << err;
        return {};
    }
    const QString path = writeTempBlob(env, "publish");
    if (path.isEmpty()) {
        qWarning() << "LotionPlugin: writing temp envelope failed";
    }
    return path;
}

QByteArray LotionPlugin::buildEnvelope(const QString& title,
                                           const QString& body,
                                           const QString& password,
                                           const QJsonObject& metaObj,
                                           QString* errOut)
{
    QJsonObject env;
    env["v"]       = 1;
    env["private"] = !password.isEmpty();

    if (password.isEmpty()) {
        env["title"] = title;
        env["body"]  = body;
        // Public envelopes carry meta in the clear so any reader (or
        // future indexer) can see `publishedAt`, `cover`, etc. without
        // decrypting. Don't let meta overwrite the protected keys.
        for (auto it = metaObj.constBegin(); it != metaObj.constEnd(); ++it) {
            const QString k = it.key();
            if (k == "v" || k == "private" || k == "title" || k == "body") continue;
            env.insert(k, it.value());
        }
        return QJsonDocument(env).toJson(QJsonDocument::Compact);
    }

    QJsonObject inner;
    inner["title"] = title;
    inner["body"]  = body;
    // Private envelopes hide meta inside the ciphertext so private posts
    // don't leak their publish time or cover choice to non-readers.
    for (auto it = metaObj.constBegin(); it != metaObj.constEnd(); ++it) {
        const QString k = it.key();
        if (k == "title" || k == "body") continue;
        inner.insert(k, it.value());
    }
    const QByteArray innerBytes =
        QJsonDocument(inner).toJson(QJsonDocument::Compact);

    const QByteArray salt  = randomBytes(16);
    const QByteArray nonce = randomBytes(12);
    const QByteArray key   = deriveKey(password, salt, 200000);
    if (key.isEmpty()) {
        if (errOut) *errOut = "PBKDF2 derivation failed";
        return {};
    }

    QByteArray ciphertext, tag;
    if (!aesGcmEncrypt(key, nonce, innerBytes, &ciphertext, &tag)) {
        if (errOut) *errOut = "AES-256-GCM encrypt failed";
        return {};
    }

    env["kdf"]        = "PBKDF2-HMAC-SHA256";
    env["iter"]       = 200000;
    env["salt"]       = QString::fromLatin1(salt.toBase64());
    env["nonce"]      = QString::fromLatin1(nonce.toBase64());
    env["tag"]        = QString::fromLatin1(tag.toBase64());
    env["ciphertext"] = QString::fromLatin1(ciphertext.toBase64());
    return QJsonDocument(env).toJson(QJsonDocument::Compact);
}

// ── envelope read + decrypt ──────────────────────────────────────────

QString LotionPlugin::consumeEnvelopeFile(const QString& path,
                                              const QString& password)
{
    auto err = [](const QString& msg) {
        QJsonObject o;
        o["ok"]    = false;
        o["error"] = msg;
        return jsonString(o);
    };
    auto needsPw = [](const QString& msg) {
        QJsonObject o;
        o["ok"]            = false;
        o["needsPassword"] = true;
        o["error"]         = msg;
        return jsonString(o);
    };

    if (path.isEmpty()) return err("no path provided");

    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        return err("could not open downloaded envelope file");
    }
    const QByteArray bytes = f.readAll();
    f.close();
    if (bytes.isEmpty()) return err("downloaded file is empty");

    QJsonParseError jerr{};
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &jerr);
    if (jerr.error != QJsonParseError::NoError || !doc.isObject()) {
        return err("envelope is not valid JSON");
    }
    const QJsonObject env = doc.object();
    if (env.value("v").toInt() != 1) {
        return err("unsupported envelope version");
    }

    const bool isPriv = env.value("private").toBool();

    auto passthroughExtras = [](const QJsonObject& src, QJsonObject* dst,
                                std::initializer_list<const char*> skip) {
        for (auto it = src.constBegin(); it != src.constEnd(); ++it) {
            const QString k = it.key();
            bool drop = false;
            for (const char* s : skip) if (k == QLatin1String(s)) { drop = true; break; }
            if (drop) continue;
            dst->insert(k, it.value());
        }
    };

    if (!isPriv) {
        QJsonObject o;
        o["ok"]        = true;
        o["isPrivate"] = false;
        o["title"]     = env.value("title").toString();
        o["body"]      = env.value("body").toString();
        // Pass through everything else (publishedAt, cover, future
        // fields) so the UI can render meta without redownloading.
        passthroughExtras(env, &o,
            {"v", "private", "title", "body",
             "salt", "nonce", "tag", "ciphertext", "kdf", "iter"});
        QFile::remove(path);
        return jsonString(o);
    }

    if (password.isEmpty()) {
        // Keep the file so a retry with a password doesn't redownload.
        return needsPw("this article is private — enter the password");
    }

    const QByteArray salt  = QByteArray::fromBase64(env.value("salt").toString().toLatin1());
    const QByteArray nonce = QByteArray::fromBase64(env.value("nonce").toString().toLatin1());
    const QByteArray tag   = QByteArray::fromBase64(env.value("tag").toString().toLatin1());
    const QByteArray ct    = QByteArray::fromBase64(env.value("ciphertext").toString().toLatin1());
    const int iter         = env.value("iter").toInt(200000);

    if (salt.size() != 16 || nonce.size() != 12 || tag.size() != 16 || ct.isEmpty()) {
        return err("envelope crypto fields malformed");
    }

    const QByteArray key = deriveKey(password, salt, iter);
    if (key.isEmpty()) {
        return err("key derivation failed");
    }

    QByteArray pt;
    if (!aesGcmDecrypt(key, nonce, ct, tag, &pt)) {
        // GCM tag mismatch — wrong password or tampered envelope.
        // Treat as needs-password so the user can retry; the file stays.
        return needsPw("wrong password (or envelope tampered)");
    }

    const QJsonDocument innerDoc = QJsonDocument::fromJson(pt);
    if (!innerDoc.isObject()) {
        return err("decrypted payload not JSON");
    }
    const QJsonObject inner = innerDoc.object();

    QJsonObject o;
    o["ok"]        = true;
    o["isPrivate"] = true;
    o["title"]     = inner.value("title").toString();
    o["body"]      = inner.value("body").toString();
    // Same passthrough for private — meta lives in the inner payload.
    passthroughExtras(inner, &o, {"title", "body"});
    QFile::remove(path);
    return jsonString(o);
}

// ── crypto ───────────────────────────────────────────────────────────

QByteArray LotionPlugin::deriveKey(const QString& password,
                                       const QByteArray& salt,
                                       int iterations)
{
    const QByteArray pw = password.toUtf8();
    QByteArray key(32, Qt::Uninitialized);
    const int ok = PKCS5_PBKDF2_HMAC(
        pw.constData(), pw.size(),
        reinterpret_cast<const unsigned char*>(salt.constData()), salt.size(),
        iterations,
        EVP_sha256(),
        key.size(),
        reinterpret_cast<unsigned char*>(key.data()));
    if (ok != 1) return {};
    return key;
}

bool LotionPlugin::aesGcmEncrypt(const QByteArray& key,
                                     const QByteArray& nonce,
                                     const QByteArray& plaintext,
                                     QByteArray* ciphertext, QByteArray* tag)
{
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return false;

    bool ok = false;
    do {
        if (1 != EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr)) break;
        if (1 != EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, nonce.size(), nullptr)) break;
        if (1 != EVP_EncryptInit_ex(ctx, nullptr, nullptr,
                reinterpret_cast<const unsigned char*>(key.constData()),
                reinterpret_cast<const unsigned char*>(nonce.constData()))) break;

        ciphertext->resize(plaintext.size());
        int outLen = 0;
        if (1 != EVP_EncryptUpdate(ctx,
                reinterpret_cast<unsigned char*>(ciphertext->data()), &outLen,
                reinterpret_cast<const unsigned char*>(plaintext.constData()),
                plaintext.size())) break;
        int finalLen = 0;
        if (1 != EVP_EncryptFinal_ex(ctx,
                reinterpret_cast<unsigned char*>(ciphertext->data()) + outLen,
                &finalLen)) break;
        ciphertext->resize(outLen + finalLen);

        tag->resize(16);
        if (1 != EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, tag->size(),
                tag->data())) break;
        ok = true;
    } while (false);

    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

bool LotionPlugin::aesGcmDecrypt(const QByteArray& key,
                                     const QByteArray& nonce,
                                     const QByteArray& ciphertext,
                                     const QByteArray& tag,
                                     QByteArray* plaintext)
{
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return false;

    bool ok = false;
    do {
        if (1 != EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr)) break;
        if (1 != EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, nonce.size(), nullptr)) break;
        if (1 != EVP_DecryptInit_ex(ctx, nullptr, nullptr,
                reinterpret_cast<const unsigned char*>(key.constData()),
                reinterpret_cast<const unsigned char*>(nonce.constData()))) break;

        plaintext->resize(ciphertext.size());
        int outLen = 0;
        if (1 != EVP_DecryptUpdate(ctx,
                reinterpret_cast<unsigned char*>(plaintext->data()), &outLen,
                reinterpret_cast<const unsigned char*>(ciphertext.constData()),
                ciphertext.size())) break;

        if (1 != EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, tag.size(),
                const_cast<char*>(tag.constData()))) break;

        int finalLen = 0;
        // Returns >0 iff the GCM tag verified.
        if (1 != EVP_DecryptFinal_ex(ctx,
                reinterpret_cast<unsigned char*>(plaintext->data()) + outLen,
                &finalLen)) break;
        plaintext->resize(outLen + finalLen);
        ok = true;
    } while (false);

    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

// ── sqlite workspace ───────────────────────────────────────────────────
//
// One table — `documents` — holds the user's Notion-style pages. A page is
// always a local row; `cid`/`published_at` are NULL until the user chooses
// to publish it to logos-storage. Nothing here touches storage; publishing
// is a separate, optional step driven from the QML.

bool LotionPlugin::openDatabase()
{
    const QString dataDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);
    // Kept as "publishing.db" (not "lotion.db") so pages created before the
    // rename carry over — the filename is never user-visible.
    const QString dbPath = dataDir + "/publishing.db";

    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", SQL_CONNECTION);
    db.setDatabaseName(dbPath);
    if (!db.open()) {
        qWarning() << "LotionPlugin: cannot open" << dbPath << db.lastError();
        return false;
    }

    QSqlQuery q(db);
    if (!q.exec("CREATE TABLE IF NOT EXISTS documents ("
                "  id           INTEGER PRIMARY KEY AUTOINCREMENT,"
                "  title        TEXT    NOT NULL DEFAULT '',"
                "  body         TEXT    NOT NULL DEFAULT '',"
                "  cover        TEXT    NOT NULL DEFAULT 'default',"
                "  is_private   INTEGER NOT NULL DEFAULT 0,"
                "  cid          TEXT,"
                "  parent_id    INTEGER,"
                "  icon         TEXT    NOT NULL DEFAULT '',"
                "  created_at   INTEGER NOT NULL,"
                "  updated_at   INTEGER NOT NULL,"
                "  published_at INTEGER"
                ")")) {
        qWarning() << "LotionPlugin: create table failed:" << q.lastError();
        return false;
    }

    // Migrations: add columns to pre-existing databases. SQLite lacks
    // "ADD COLUMN IF NOT EXISTS", so check the schema first.
    QSet<QString> cols;
    QSqlQuery info(db);
    if (info.exec("PRAGMA table_info(documents)"))
        while (info.next()) cols.insert(info.value(1).toString());
    auto ensureCol = [&](const QString& name, const QString& decl) {
        if (cols.contains(name)) return;
        QSqlQuery alt(db);
        if (!alt.exec("ALTER TABLE documents ADD COLUMN " + name + " " + decl))
            qWarning() << "LotionPlugin: add column" << name << "failed:" << alt.lastError();
    };
    ensureCol("parent_id", "INTEGER");
    ensureCol("icon",      "TEXT NOT NULL DEFAULT ''");

    qDebug() << "LotionPlugin: SQLite ready at" << dbPath;
    return true;
}

int LotionPlugin::createDocument()
{
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return -1;

    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QSqlQuery q(db);
    q.prepare("INSERT INTO documents (title, body, cover, is_private, "
              "created_at, updated_at) VALUES ('', '', 'default', 0, ?, ?)");
    q.addBindValue(now);
    q.addBindValue(now);
    if (!q.exec()) {
        qWarning() << "LotionPlugin::createDocument:" << q.lastError();
        return -1;
    }
    const int id = q.lastInsertId().toInt();
    emit eventResponse("documentsChanged", QVariantList{});
    return id;
}

int LotionPlugin::createChildDocument(const QString& parentId)
{
    bool ok = false;
    const int pid = parentId.toInt(&ok);
    if (!ok) return createDocument();   // no parent → root page
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return -1;

    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QSqlQuery q(db);
    q.prepare("INSERT INTO documents (title, body, cover, is_private, parent_id, "
              "created_at, updated_at) VALUES ('', '', 'default', 0, ?, ?, ?)");
    q.addBindValue(pid);
    q.addBindValue(now);
    q.addBindValue(now);
    if (!q.exec()) {
        qWarning() << "LotionPlugin::createChildDocument:" << q.lastError();
        return -1;
    }
    const int id = q.lastInsertId().toInt();
    emit eventResponse("documentsChanged", QVariantList{});
    return id;
}

bool LotionPlugin::renameDocument(const QString& id, const QString& title)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return false;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return false;
    QSqlQuery q(db);
    q.prepare("UPDATE documents SET title = COALESCE(?, ''), updated_at = ? WHERE id = ?");
    q.addBindValue(title);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(docId);
    // No documentsChanged emit — renames happen per keystroke from the
    // kanban card; the sidebar refreshes on the next navigation.
    return q.exec() && q.numRowsAffected() > 0;
}

bool LotionPlugin::setIcon(const QString& id, const QString& icon)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return false;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return false;
    QSqlQuery q(db);
    q.prepare("UPDATE documents SET icon = COALESCE(?, ''), updated_at = ? WHERE id = ?");
    q.addBindValue(icon);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(docId);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    emit eventResponse("documentsChanged", QVariantList{});
    return true;
}

bool LotionPlugin::setParent(const QString& id, const QString& parentId)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return false;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return false;

    bool pok = false;
    const int pid = parentId.toInt(&pok);   // "" / non-numeric → root
    const bool toRoot = !pok || pid < 0;

    if (!toRoot) {
        if (pid == docId) return false;       // can't parent to self
        // Reject cycles: walk up from the new parent; if we reach docId, abort.
        int cur = pid, guard = 0;
        while (cur > 0 && guard < 1000) {
            if (cur == docId) return false;
            QSqlQuery up(db);
            up.prepare("SELECT parent_id FROM documents WHERE id = ?");
            up.addBindValue(cur);
            if (!up.exec() || !up.next() || up.value(0).isNull()) break;
            cur = up.value(0).toInt();
            guard++;
        }
    }

    QSqlQuery q(db);
    q.prepare("UPDATE documents SET parent_id = ?, updated_at = ? WHERE id = ?");
    q.addBindValue(toRoot ? QVariant() : QVariant(pid));
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(docId);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    emit eventResponse("documentsChanged", QVariantList{});
    return true;
}

int LotionPlugin::duplicateDocument(const QString& id)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return -1;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return -1;

    QSqlQuery sel(db);
    sel.prepare("SELECT title, body, cover, is_private, parent_id, icon FROM documents WHERE id = ?");
    sel.addBindValue(docId);
    if (!sel.exec() || !sel.next()) return -1;

    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QSqlQuery ins(db);
    ins.prepare("INSERT INTO documents (title, body, cover, is_private, parent_id, icon, "
                "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)");
    ins.addBindValue(sel.value(0).toString() + " (copy)");
    ins.addBindValue(sel.value(1).toString());
    ins.addBindValue(sel.value(2).toString());
    ins.addBindValue(sel.value(3).toInt());
    ins.addBindValue(sel.value(4).isNull() ? QVariant() : sel.value(4).toInt());
    ins.addBindValue(sel.value(5).toString());
    ins.addBindValue(now);
    ins.addBindValue(now);
    if (!ins.exec()) {
        qWarning() << "LotionPlugin::duplicateDocument:" << ins.lastError();
        return -1;
    }
    emit eventResponse("documentsChanged", QVariantList{});
    return ins.lastInsertId().toInt();
}

bool LotionPlugin::saveDocument(const QString& id, const QString& title,
                                    const QString& body, const QString& cover,
                                    const QString& isPrivate)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return false;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return false;

    QSqlQuery q(db);
    // COALESCE(?, '') so an empty title/body that arrives over IPC as a
    // NULL still satisfies the NOT NULL columns (otherwise a page with no
    // body — e.g. a freshly-created sub-page — fails to save).
    q.prepare("UPDATE documents SET title = COALESCE(?, ''), body = COALESCE(?, ''), "
              "cover = ?, is_private = ?, updated_at = ? WHERE id = ?");
    q.addBindValue(title);
    q.addBindValue(body);
    q.addBindValue(cover.isEmpty() ? QStringLiteral("default") : cover);
    q.addBindValue(parseBoolish(isPrivate) ? 1 : 0);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(docId);
    if (!q.exec()) {
        qWarning() << "LotionPlugin::saveDocument:" << q.lastError();
        return false;
    }
    // No documentsChanged here — autosave fires often and the UI refreshes
    // its own list after the save returns. Emitting would churn the sidebar.
    return q.numRowsAffected() > 0;
}

QString LotionPlugin::listDocuments()
{
    QJsonArray arr;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    QSqlQuery q(db);
    if (q.exec("SELECT id, title, body, cover, is_private, cid, "
               "updated_at, published_at, parent_id, icon FROM documents "
               "ORDER BY updated_at DESC")) {
        while (q.next()) {
            const QString body = q.value(2).toString();
            QJsonObject obj;
            obj["id"]          = q.value(0).toInt();
            obj["title"]       = q.value(1).toString();
            obj["icon"]        = q.value(9).toString();
            // First ~120 chars of body, newlines flattened, for the
            // sidebar preview line.
            QString snippet = body;
            snippet.replace('\n', ' ');
            if (snippet.size() > 120) snippet = snippet.left(120);
            obj["snippet"]     = snippet;
            obj["cover"]       = q.value(3).toString();
            obj["isPrivate"]   = q.value(4).toBool();
            obj["cid"]         = q.value(5).isNull() ? QJsonValue()
                                                     : QJsonValue(q.value(5).toString());
            obj["updatedAt"]   = q.value(6).toDouble();
            obj["publishedAt"] = q.value(7).isNull() ? QJsonValue()
                                                     : QJsonValue(q.value(7).toDouble());
            obj["parentId"]    = q.value(8).isNull() ? QJsonValue()
                                                     : QJsonValue(q.value(8).toInt());
            arr.append(obj);
        }
    } else {
        qWarning() << "LotionPlugin::listDocuments:" << q.lastError();
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QString LotionPlugin::getDocument(const QString& id)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return QStringLiteral("{}");
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    QSqlQuery q(db);
    q.prepare("SELECT id, title, body, cover, is_private, cid, "
              "updated_at, published_at, parent_id, icon FROM documents WHERE id = ?");
    q.addBindValue(docId);
    if (!q.exec() || !q.next()) return QStringLiteral("{}");

    QJsonObject obj;
    obj["id"]          = q.value(0).toInt();
    obj["title"]       = q.value(1).toString();
    obj["icon"]        = q.value(9).toString();
    obj["body"]        = q.value(2).toString();
    obj["cover"]       = q.value(3).toString();
    obj["isPrivate"]   = q.value(4).toBool();
    obj["cid"]         = q.value(5).isNull() ? QJsonValue()
                                             : QJsonValue(q.value(5).toString());
    obj["updatedAt"]   = q.value(6).toDouble();
    obj["publishedAt"] = q.value(7).isNull() ? QJsonValue()
                                             : QJsonValue(q.value(7).toDouble());
    obj["parentId"]    = q.value(8).isNull() ? QJsonValue()
                                             : QJsonValue(q.value(8).toInt());
    return jsonString(obj);
}

bool LotionPlugin::deleteDocument(const QString& id)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok) return false;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    if (!db.isOpen()) return false;

    // Delete the page and all of its descendants (a sub-tree). Gather ids
    // breadth-first, then delete in one pass.
    QList<int> toDelete;
    toDelete.append(docId);
    for (int i = 0; i < toDelete.size(); ++i) {
        QSqlQuery kids(db);
        kids.prepare("SELECT id FROM documents WHERE parent_id = ?");
        kids.addBindValue(toDelete[i]);
        if (kids.exec()) while (kids.next()) toDelete.append(kids.value(0).toInt());
    }
    bool any = false;
    for (int delId : toDelete) {
        QSqlQuery q(db);
        q.prepare("DELETE FROM documents WHERE id = ?");
        q.addBindValue(delId);
        if (q.exec() && q.numRowsAffected() > 0) any = true;
    }
    if (any) emit eventResponse("documentsChanged", QVariantList{});
    return any;
}

bool LotionPlugin::markPublished(const QString& id, const QString& cid)
{
    bool ok = false;
    const int docId = id.toInt(&ok);
    if (!ok || cid.isEmpty()) return false;
    QSqlDatabase db = QSqlDatabase::database(SQL_CONNECTION);
    QSqlQuery q(db);
    q.prepare("UPDATE documents SET cid = ?, published_at = ? WHERE id = ?");
    q.addBindValue(cid);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(docId);
    if (!q.exec() || q.numRowsAffected() == 0) return false;
    emit eventResponse("documentsChanged", QVariantList{});
    return true;
}

// ── cover image import ─────────────────────────────────────────────────

QString LotionPlugin::ensureCoversDir(const QString& destDir)
{
    // The QML passes a folder inside the plugin's own dir — the one place
    // Basecamp's QML sandbox will load an Image from. Fall back to app data
    // if (somehow) empty, though Image won't render from there.
    QString dir = destDir.trimmed();
    if (dir.startsWith("file://")) dir = QUrl(dir).toLocalFile();
    if (dir.isEmpty()) {
        dir = QDir::cleanPath(
            QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/covers");
    }
    QDir().mkpath(dir);
    return dir;
}

QString LotionPlugin::importCoverImage(const QString& srcUrl,
                                           const QString& destDir)
{
    if (srcUrl.isEmpty()) return {};

    // Accept a file:// URL or a bare path.
    QString src = srcUrl.trimmed();
    const QUrl u(src);
    if (u.isLocalFile())          src = u.toLocalFile();
    else if (src.startsWith("file://")) src = QUrl(src).toLocalFile();

    QFileInfo fi(src);
    if (!fi.exists() || !fi.isFile()) {
        qWarning() << "LotionPlugin::importCoverImage: not a file:" << src;
        return {};
    }
    const QString ext = fi.suffix().toLower();
    static const QStringList okExt =
        { "png", "jpg", "jpeg", "gif", "webp", "bmp" };
    if (!okExt.contains(ext)) {
        qWarning() << "LotionPlugin::importCoverImage: unsupported type:" << ext;
        return {};
    }

    const QString coversDir = ensureCoversDir(destDir);
    const QString dest = coversDir + "/" +
        QUuid::createUuid().toString(QUuid::WithoutBraces) + "." + ext;

    if (!QFile::copy(src, dest)) {
        qWarning() << "LotionPlugin::importCoverImage: copy failed"
                   << src << "->" << dest;
        return {};
    }
    qInfo().noquote() << "LotionPlugin: imported cover image to" << dest;
    return dest;
}

// ── temp file ────────────────────────────────────────────────────────

QString LotionPlugin::writeTempBlob(const QByteArray& bytes,
                                        const QString& tag)
{
    const QString path = cacheDir() + "/" + tag + "-" +
        QUuid::createUuid().toString(QUuid::WithoutBraces) + ".env";
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "LotionPlugin::writeTempBlob open failed:" << path;
        return {};
    }
    if (f.write(bytes) != bytes.size()) {
        qWarning() << "LotionPlugin::writeTempBlob short write:" << path;
        f.close();
        QFile::remove(path);
        return {};
    }
    f.close();
    return path;
}
