#ifndef COUNTER_PLUGIN_H
#define COUNTER_PLUGIN_H

#include <QObject>
#include <QProcess>
#include <QString>
#include <QVariantList>

#include "counter_interface.h"
#include "logos_api.h"
#include "logos_sdk.h"

class CounterPlugin : public QObject, public CounterInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID CounterInterface_iid FILE "metadata.json")
    Q_INTERFACES(CounterInterface PluginInterface)

public:
    explicit CounterPlugin(QObject* parent = nullptr);
    ~CounterPlugin() override;

    QString name()    const override { return "counter"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE int     chainStatus() override;
    Q_INVOKABLE QString lastError() override;
    Q_INVOKABLE bool    increment() override;
    Q_INVOKABLE bool    refresh() override;
    Q_INVOKABLE QString currentCount() override;
    Q_INVOKABLE QString sequencerUrl() override;
    Q_INVOKABLE bool    setSequencerUrl(const QString& url) override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    void setChainStatus(int status);
    QString runCli(const QStringList& args, int timeoutMs = 60 * 1000);
    void kickRefresh();        // non-blocking; fires off a `spel inspect`

    int     m_chainStatus = 0;
    QString m_lastError;
    qint64  m_lastCount   = 0;
    qint64  m_fetchedAtSecs = 0;
    QString m_sequencerUrl;

    bool    m_refreshInFlight = false;
    QProcess* m_inflightProc  = nullptr;
};

#endif
