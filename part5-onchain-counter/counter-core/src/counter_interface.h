#ifndef COUNTER_INTERFACE_H
#define COUNTER_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class CounterInterface : public PluginInterface
{
public:
    virtual ~CounterInterface() = default;

    // Chain status — 0=unconfigured, 1=checking, 2=ready, 3=error
    Q_INVOKABLE virtual int     chainStatus() = 0;
    Q_INVOKABLE virtual QString lastError() = 0;

    // Primary actions — both are async. QML polls currentCount() + chainStatus()
    // at ~1 s cadence for UI updates.
    Q_INVOKABLE virtual bool    increment() = 0;
    Q_INVOKABLE virtual bool    refresh() = 0;

    // Last read value (JSON: {"count": N, "fetchedAt": <iso8601>})
    Q_INVOKABLE virtual QString currentCount() = 0;

    // Where is the program deployed? The plugin auto-reads this from the
    // wallet config by default, but the UI can override for workshop demos.
    Q_INVOKABLE virtual QString sequencerUrl() = 0;
    Q_INVOKABLE virtual bool    setSequencerUrl(const QString& url) = 0;
};

#define CounterInterface_iid "org.logos.CounterInterface"
Q_DECLARE_INTERFACE(CounterInterface, CounterInterface_iid)

#endif
