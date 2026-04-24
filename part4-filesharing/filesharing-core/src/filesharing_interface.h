#ifndef FILESHARING_INTERFACE_H
#define FILESHARING_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class FileSharingInterface : public PluginInterface
{
public:
    virtual ~FileSharingInterface() = default;

    // Storage node lifecycle — 0=off, 1=starting, 2=running, 3=error
    Q_INVOKABLE virtual bool    startStorage() = 0;
    Q_INVOKABLE virtual bool    stopStorage() = 0;
    Q_INVOKABLE virtual int     storageStatus() = 0;
    Q_INVOKABLE virtual QString lastError() = 0;

    // Upload / download — both are async. UI polls the state helpers below
    // to render progress and the resulting CID.
    Q_INVOKABLE virtual QString uploadFile(const QString& fileUrl) = 0;
    Q_INVOKABLE virtual bool    downloadFile(const QString& cid, const QString& destUrl) = 0;

    // Remove a CID from the local store.
    Q_INVOKABLE virtual bool    removeFile(const QString& cid) = 0;

    // JSON views for the UI.
    Q_INVOKABLE virtual QString listFiles() = 0;        // local manifests
    Q_INVOKABLE virtual QString currentUpload() = 0;    // last/in-flight upload
    Q_INVOKABLE virtual QString currentDownload() = 0;  // last/in-flight download
};

#define FileSharingInterface_iid "org.logos.FileSharingInterface"
Q_DECLARE_INTERFACE(FileSharingInterface, FileSharingInterface_iid)

#endif
