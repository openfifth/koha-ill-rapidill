(function () {
    // Map Standard ILL type values to RapidILL type values
    var rapidTypeMap = {
        article: 'Article',
        book: 'Book',
        chapter: 'BookChapter',
    };

    function isOpac() {
        return /opac/.test(window.location.pathname);
    }

    var debounceTimeout;

    function debounce(func, wait) {
        return function () {
            var context = this,
                args = arguments;
            clearTimeout(debounceTimeout);
            debounceTimeout = setTimeout(function () {
                func.apply(context, args);
            }, wait);
        };
    }

    function makeApiCall(endpoint, data, callback) {
        $.post({
            url: '/api/v1/contrib/rapidill/' + endpoint,
            data: JSON.stringify(data),
            contentType: 'application/json',
        }).done(function (resp) {
            callback(resp);
        });
    }

    function handleRequestabilityResponse(response) {
        $('#request-lookup').hide();
        $('#request-possible').hide();
        $('#request-notpossible').hide();

        if (response.holdings) {
            var local = response.holdings.map(function (h) {
                return (
                    '<li><a href="' +
                    h.RapidRedirectUrl +
                    '" target="_blank">' +
                    h.RapidRedirectUrl +
                    '</a></li>'
                );
            });
            $('#request-notpossible').show();
            $('#localholdings')
                .append(
                    '<p>' +
                        _('Item is available locally') +
                        ':</p><ul>' +
                        local.join('') +
                        '</ul>'
                )
                .show();
        } else {
            // Remote requestability is only shown to intranet staff
            if (isOpac()) return;
            var canRequest = response.canRequest;
            if (
                canRequest.FoundMatch === 1 &&
                canRequest.NumberOfAvailableHoldings > 0
            ) {
                $('#request-possible').show();
            } else {
                $('#errormessage')
                    .append(
                        '<span>' +
                            canRequest.VerificationNote.replace('\n', ', ') +
                            '</span>'
                    )
                    .show();
                $('#request-notpossible').show();
            }
        }
    }

    // Build a RapidILL metadata object from Standard form field values,
    // using the fieldmap's ill/ill_map properties to locate the right inputs
    function gatherMetadata() {
        var standardType = $('#type').val();
        var rapidType = rapidTypeMap[standardType];
        if (!rapidType) return {};

        var metadata = { RapidRequestType: rapidType };

        Object.keys(rapidILLFieldmap).forEach(function (key) {
            var field = rapidILLFieldmap[key];
            if (field.exclude || field.materials.indexOf(rapidType) === -1)
                return;

            var illKey =
                field.ill_map && field.ill_map[rapidType]
                    ? field.ill_map[rapidType]
                    : field.ill;
            if (!illKey) return;

            var input = document.getElementById(illKey);
            if (!input) return;

            var val = input.value;
            if (!val || val.length === 0) return;

            if (field.type === 'string') {
                metadata[key] = val;
            } else if (field.type === 'array') {
                metadata[key] = { string: val.replace(/  +/g, ' ').split(' ') };
            }
        });

        return metadata;
    }

    function checkRequestability() {
        console.log('hello');
        $('#errormessage').empty().hide();
        $('#localholdings').empty().hide();
        $('#request-lookup').hide();
        $('#request-possible').hide();
        $('#request-notpossible').hide();

        var metadata = gatherMetadata();
        // Need more than just RapidRequestType to make a meaningful check
        if (Object.keys(metadata).length <= 1) return;

        var checkMetadata = Object.assign(
            { IsHoldingsCheckOnly: true, DoBlockLocalOnly: false },
            metadata
        );

        if (!isOpac()) {
            $('#request-lookup').show();
        }

        makeApiCall(
            'insertrequest',
            { metadata: checkMetadata, borrowerId: 0 },
            function (response) {
                var holdings = response.result;
                if (
                    holdings.LocalHoldings &&
                    holdings.LocalHoldings.LocalHoldingItem &&
                    holdings.LocalHoldings.LocalHoldingItem.length > 0
                ) {
                    handleRequestabilityResponse({
                        holdings: holdings.LocalHoldings.LocalHoldingItem,
                    });
                } else {
                    // Remote requestability check is intranet-only
                    if (isOpac()) {
                        $('#request-lookup').hide();
                        return;
                    }
                    checkMetadata.PatronNotes = 'HOLDING_CHECK_DO_REMOTE_SEARCH';
                    makeApiCall(
                        'insertrequest',
                        { metadata: checkMetadata, borrowerId: 0 },
                        function (response) {
                            handleRequestabilityResponse({
                                canRequest: response.result,
                            });
                        }
                    );
                }
            }
        );
    }

    console.log('[autoill] script loaded');

    document.addEventListener('DOMContentLoaded', function () {
        console.log('[autoill] DOMContentLoaded fired');
        // Only run on the Standard ILL create form.
        // If rapid_field_* elements are present, the RapidILL form is already
        // handling this via its own backend_jsinclude block.
        if (!document.getElementById('create_form')) {
            console.log('[autoill] no #create_form, bailing');
            return;
        }
        if (document.querySelector('[id^="rapid_field_"]')) {
            console.log('[autoill] rapid_field_* found, bailing');
            return;
        }

        var typeSelect = document.getElementById('type');
        if (!typeSelect) {
            console.log('[autoill] no #type, bailing');
            return;
        }

        console.log('[autoill] setting up handlers');

        var actionFieldset = document.querySelector('#create_form fieldset.action');
        if (!actionFieldset) return;

        var spinnerPath = isOpac()
            ? '/opac-tmpl/bootstrap/images/spinner-small.gif'
            : '/intranet-tmpl/prog/img/spinner-small.gif';

        $(actionFieldset).prepend(
            '<div role="alert" class="alert alert-warning" id="request-lookup" style="display:none">' +
                _('Checking item availability via RapidILL') +
                ' <img src="' + spinnerPath + '" alt="" />' +
                '</div>' +
                '<div role="alert" class="alert alert-success" id="request-possible" style="display:none">' +
                _('Item is available for request') +
                '</div>' +
                '<div role="alert" class="alert alert-warning" id="request-notpossible" style="display:none">' +
                _('Item cannot be requested') +
                '<div id="localholdings" style="display:none;margin-top:1rem"></div>' +
                '<div id="errormessage" style="display:none"></div>' +
                '</div>'
        );

        $('#create_form input[type="text"]').on(
            'keyup',
            debounce(checkRequestability, 1000)
        );

        $('#type').on('change', debounce(checkRequestability, 300));
    });
})();
