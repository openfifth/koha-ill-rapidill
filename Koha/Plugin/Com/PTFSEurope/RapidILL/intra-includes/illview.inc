[% BLOCK backend_jsinclude %]
<style>
    #rapid_status {
        padding-top: 20px;
        display: none;
    }
    .rapid_transaction {
        display: flex;
    }
    .rapid_transaction > * {
        width: 25%;
    }
    #transactions_header {
        font-weight: 700;
        margin-bottom: 0.5rem;
    }
    #rapid_header {
        margin-bottom: 1rem;
    }
</style>
<script>
    document.addEventListener('DOMContentLoaded', function(){
        var field_map = [% whole.field_map_json %];

        var rapidIdContainer = $(".requestmeta-RapidILL_identifier");
        if (!rapidIdContainer) return;

        // We clone so we can extract the RapidID without affecting the displayed markup
        var containerClone = rapidIdContainer.clone();

        $('.page-section').first().append('<div id="rapid_status" class="rows"></div>');

        containerClone.find('span.label').remove();
        var rapidId = containerClone.text().replace(/ |\n/g,'');

        if (!rapidId || rapidId.length === 0) return;

        $.post({
            url: '/api/v1/contrib/rapidill/retrievehistory',
            data: JSON.stringify({ requestId: rapidId }),
            contentType: 'application/json'
        })
            .done(function(resp, status) {
                var body = resp.result;
                if (
                    !body ||
                    !body.IsSuccessful ||
                    !body.HistoryTransactions ||
                    !body.HistoryTransactions.TranHistory ||
                    body.HistoryTransactions.TranHistory.length === 0
                ) return;

                var transactionsHeader = '<div id="transactions_header" class="rapid_transaction">' +
                    '<div class="date">' + _('Date') + '</div>' +
                    '<div class="branch">' + _('Branch name') + '</div>' +
                    '<div class="code">' + _('RapidILL code') + '</div>' +
                    '<div class="state">' + _('RapidILL state') + '</div>' +
                    '</div>';

                var transactions = [];
                body.HistoryTransactions.TranHistory.forEach(function(tran) {
                    var tranDate = new Date(tran.TransactionDate);
                    var tranMarkup = '<div class="rapid_transaction">' +
                        '<div class="date">' + tranDate.toLocaleDateString() + ' ' + tranDate.toLocaleTimeString() + '</div>' +
                        '<div class="branch">' + tran.BranchName + '</div>' +
                        '<div class="code">' + tran.RapidCode + '</div>' +
                        '<div class="state">' + tran.StateType + '</div>' +
                        '</div>';
                    transactions.push(tranMarkup);
                });

                $('#rapid_status').append(
                    '<h1 id="rapid_header">' + _('RapidILL history') + '</h1>' +
                    transactionsHeader + 
                    transactions.join('')
                ).show();
            });

    });
</script>
[% END %]