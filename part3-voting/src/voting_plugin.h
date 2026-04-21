#ifndef VOTING_PLUGIN_H
#define VOTING_PLUGIN_H

#include <QObject>
#include <QString>
#include <QHash>
#include <QVariant>
#include "voting_interface.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

struct PollState {
    QString              question;
    QHash<QString, bool> votes;   // voterId -> yes/no (latest wins)
};

class VotingPlugin : public QObject, public VotingInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID VotingInterface_iid FILE "metadata.json")
    Q_INTERFACES(VotingInterface PluginInterface)

public:
    explicit VotingPlugin(QObject* parent = nullptr);
    ~VotingPlugin() override;

    QString name() const override { return "voting"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    startDelivery() override;
    Q_INVOKABLE bool    stopDelivery() override;
    Q_INVOKABLE int     deliveryStatus() override;

    Q_INVOKABLE bool    openPoll(const QString& pollId, const QString& question) override;
    Q_INVOKABLE bool    closePoll(const QString& pollId) override;
    Q_INVOKABLE bool    vote(const QString& pollId, bool yes) override;

    Q_INVOKABLE QString listPolls() override;
    Q_INVOKABLE QString tally(const QString& pollId) override;
    Q_INVOKABLE QString myVoterId() override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QString topicFor(const QString& pollId) const;
    QString pollIdFromTopic(const QString& topic) const;
    void    handleMessageReceived(const QVariantList& data);
    void    setDeliveryStatus(int status);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());

    QString                   m_voterId;
    QHash<QString, PollState> m_polls;

    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    int             m_deliveryStatus = 0;
    bool            m_started        = false;
};

#endif
