#ifndef FILESHARING_PLUGIN_H
#define FILESHARING_PLUGIN_H

#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include "filesharing_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

struct UploadState {
    QString sessionId;
    QString filename;
    qint64  bytes   = 0;
    QString cid;      // set on success
    QString error;    // set on failure
    int     status = 0;   // 0=idle, 1=uploading, 2=done, 3=error
};

struct DownloadState {
    QString cid;          // also the sessionId
    QString destPath;
    qint64  bytes   = 0;
    QString error;
    int     status = 0;   // 0=idle, 1=downloading, 2=done, 3=error
};

class FileSharingPlugin : public QObject, public FileSharingInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID FileSharingInterface_iid FILE "metadata.json")
    Q_INTERFACES(FileSharingInterface PluginInterface)

public:
    explicit FileSharingPlugin(QObject* parent = nullptr);
    ~FileSharingPlugin() override;

    QString name() const override { return "filesharing"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    startStorage() override;
    Q_INVOKABLE bool    stopStorage() override;
    Q_INVOKABLE int     storageStatus() override;
    Q_INVOKABLE QString lastError() override;

    Q_INVOKABLE QString uploadFile(const QString& fileUrl) override;
    Q_INVOKABLE bool    downloadFile(const QString& cid, const QString& destUrl) override;
    Q_INVOKABLE bool    removeFile(const QString& cid) override;

    Q_INVOKABLE QString listFiles() override;
    Q_INVOKABLE QString currentUpload() override;
    Q_INVOKABLE QString currentDownload() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    void setStorageStatus(int status);
    void wireEvents();
    void doInitAndStart();
    void asyncStart();
    void handleStorageStart(const QVariantList& data);
    void handleStorageStop(const QVariantList& data);
    void handleUploadProgress(const QVariantList& data);
    void handleUploadDone(const QVariantList& data);
    void handleDownloadProgress(const QVariantList& data);
    void handleDownloadDone(const QVariantList& data);

    LogosAPIClient* m_storageClient = nullptr;
    LogosObject*    m_storageObject = nullptr;

    int           m_storageStatus  = 0;
    bool          m_initialised    = false;
    int           m_initRetryCount = 0;
    QString       m_lastError;
    UploadState   m_upload;
    DownloadState m_download;

    QString       m_manifestsCache;
    bool          m_manifestsRefreshInFlight = false;
    bool          m_manifestsDirty           = false;
};

#endif
