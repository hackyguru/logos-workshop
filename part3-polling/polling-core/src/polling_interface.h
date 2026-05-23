#ifndef POLLING_INTERFACE_H
#define POLLING_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class PollingInterface : public PluginInterface
{
public:
    virtual ~PollingInterface() = default;

    // Delivery lifecycle — 0=off, 1=connecting, 2=connected, 3=error
    Q_INVOKABLE virtual bool    startDelivery() = 0;
    Q_INVOKABLE virtual bool    stopDelivery() = 0;
    Q_INVOKABLE virtual int     deliveryStatus() = 0;

    // Polls — each poll is a content topic /polling/1/poll-<id>/json
    Q_INVOKABLE virtual bool    openPoll(const QString& pollId, const QString& question) = 0;
    Q_INVOKABLE virtual bool    closePoll(const QString& pollId) = 0;
    Q_INVOKABLE virtual bool    vote(const QString& pollId, bool yes) = 0;

    // Query helpers (return compact JSON)
    Q_INVOKABLE virtual QString listPolls() = 0;
    Q_INVOKABLE virtual QString tally(const QString& pollId) = 0;
    Q_INVOKABLE virtual QString myVoterId() = 0;
};

#define PollingInterface_iid "org.logos.PollingInterface"
Q_DECLARE_INTERFACE(PollingInterface, PollingInterface_iid)

#endif
