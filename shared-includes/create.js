// Show or hide fields depending on selected type
function showFields() {
    var selected = $('#type').val();
    Object.keys(fieldmap).forEach(function (key) {
        if (fieldmap[key].materials.indexOf(selected) == -1) {
            $('#rapid_field_' + key).hide();
        } else {
            $('#rapid_field_' + key).show();
        }
    });
};

// Build the groups used for validation
function buildValidationGroups() {
    var groups = {};
    Object.keys(fieldmap).forEach(function (field) {
        if (fieldmap[field].required) {
            var req = fieldmap[field].required;
            Object.keys(req).forEach(function (material) {
                if (material === $('#type').val()) {
                    if (!groups[req[material].group]) {
                        groups[req[material].group] = [field];
                    } else {
                        groups[req[material].group].push(field);
                    }
                }
            });
        }
    });
    return groups;
};

// Does a given group of fields have at least one populated input?
function isGroupValid(fields) {
    var filtered = fields.filter(function (field) {
        if ($('#rapid_field_' + field + ' input').val().length > 0) {
            return field;
        }
    });
    return filtered.length > 0;
};

// Show / hide warning and manage content
function manageWarning(messages) {
    var warning = $('#rapid_warning');
    if (messages.length === 0) {
        warning.css('visibility', 'hidden');
        warning.empty();
    } else {
        var listItems = messages.map(function (message) {
            return "<li>" + message + "</li>";
        });
        var content = '<ul id="rapid_warnings">' + listItems.join('') + "</ul>"
        warning.empty();
        warning.append(content);
        warning.css('visibility', 'visible');
    }
};

function isOpac() {
    var re = new RegExp(/opac/);
    return re.test(window.location.pathname);
}

// Enable / disable submit button based on validation
// but only on intranet
function manageSubmit(messages) {
    if (!isOpac()) {
        $("#rapid_submit").attr('disabled', messages.length > 0);
    }
}

// Add event handlers for fields that need them
function addHandlers() {
    var handleMe = [];
    Object.keys(fieldmap).forEach(function (field) {
        if (fieldmap[field].required && $("#" + field).is(':visible')) {
            handleMe.push("#rapid_field_" + field + " input");
        }
    });
    // Add the fields that cannot be empty
    handleMe = handleMe.concat(notEmpty.map(function (ne) {
        return '#' + ne;
    }));
    if (handleMe.length > 0) {
        var selectors = handleMe.join(',');

        // Remove pre-existing handlers
        if (listenerSelectors.length > 0) {
            $(selectors).off('keyup')
        }

        $(selectors).on('keyup', function () {
            validateFields();
            listenerSelectors = selectors;
        });
    }
};

// Check the requestability and local holdings of an item
// This requires two API calls, we look at the response of
// both to establish what availability we have
function requestability(messages) {

    if (messages.length > 0) return;

    $('#errormessage').empty().css('display', 'none');
    $('#localholdings').empty().css('display', 'none');
    $('#request-lookup').css('display', 'none');
    $('#request-possible').css('display', 'none');
    $('#request-notpossible').css('display', 'none');

    // Get our provided metadata
    var providedMetadata = gatherMetadata();
    // If we don't have any, we can't continue;
    if (Object.keys(providedMetadata).length === 0) return;

    // First, is this item available locally
    var baseMetadata = {
        IsHoldingsCheckOnly: true,
        DoBlockLocalOnly: false,
    };

    // Merge it with our base metadata
    var metadata = Object.assign(baseMetadata, providedMetadata);

    // Show that we're doing something
    $('#request-lookup').css('display', 'block');

    makeApiCall(
        'insertrequest',
        { metadata: metadata, borrowerId: 0 },
        // Slight meander into callback hell
        function (response) {
            var holdings = response.result;

            // If we have local holdings, we won't be able to
            // place a request so we should just report the holdings
            if (
                holdings.LocalHoldings &&
                holdings.LocalHoldings.LocalHoldingItem &&
                holdings.LocalHoldings.LocalHoldingItem.length > 0) {
                handleRequestabilityResponse({ holdings: holdings.LocalHoldings.LocalHoldingItem });
            } else {
                // Now check requestability
                // Adding the PatronNotes indicates that we want remote
                // availability
                metadata.PatronNotes = 'HOLDING_CHECK_DO_REMOTE_SEARCH';
                makeApiCall(
                    'insertrequest',
                    { metadata: metadata, borrowerId: 0 },
                    function (response) {
                        // Handle our responses
                        handleRequestabilityResponse({
                            canRequest: response.result
                        });
                    }
                );
            }
        }
    );
};

// Make an API call
function makeApiCall(endpoint, data, callback) {
    $.post({
        url: '/api/v1/contrib/rapidill/' + endpoint,
        data: JSON.stringify(data),
        contentType: 'application/json'
    })
        .done(function (resp, status) {
            callback(resp);
        });
};

// Simple debounce
// Returns a function, that, as long as it continues to be invoked, will not
// be triggered. The function will be called after it stops being called for
// N milliseconds. If `immediate` is passed, trigger the function on the
// leading edge, instead of the trailing.
// Taken from: https://davidwalsh.name/javascript-debounce-function
var timeout;
function debounce(func, wait, immediate) {
    return function () {
        var context = this,
            args = arguments;
        var later = function () {
            timeout = null;
            if (!immediate) func.apply(context, args);
        };
        var callNow = immediate && !timeout;
        clearTimeout(timeout);
        timeout = setTimeout(later, wait);
        if (callNow) func.apply(context, args);
    };
}

// Handle lookup response
function handleRequestabilityResponse(response) {
    $('#request-lookup').css('display', 'none');
    $('#request-possible').css('display', 'none');
    $('#request-notpossible').css('display', 'none');

    // If we got back local holdings
    if (response.holdings) {
        var local = [];
        response.holdings.forEach(function (holding) {
            local.push('<li><a href="' + holding.RapidRedirectUrl + '" target="_blank">' + holding.RapidRedirectUrl + '</a></li>');
        });
        $('#request-notpossible').css('display', 'block');
        $('#localholdings').append(
            '<p>' + _('Item is available locally') + ':</p>' +
            '<ul>' + local.join('') + '</ul>'
        ).show();
    } else {
        // No local holdings so we need to establish if this item is available for
        // request, but only in intranet
        if (isOpac()) return;
        if (
            response.canRequest.FoundMatch === 1 &&
            response.canRequest.NumberOfAvailableHoldings > 0
        ) {
            // This item is available for request
            $('#request-possible').css('display', 'block');
        } else {
            // Not available for request, display why
            $('#errormessage').append('<span>' + response.canRequest.VerificationNote.replace('\n', ', ') + '</span>').show();
            $('#request-notpossible').css('display', 'block');
        }
    }
};

// Iterate our fields for this material type and gather any provided values
function gatherMetadata() {
    var type = $('#type').val();

    var metadata = {
        RapidRequestType: type
    };

    Object.keys(fieldmap).filter(function (key) {
        if (fieldmap[key].materials.indexOf(type) != -1) {
            var val = $('#' + key).val();
            if (val && val.length > 0) {
                if (fieldmap[key].type === 'string') {
                    metadata[key] = val;
                } else if (fieldmap[key].type === 'array') {
                    val = val.replace(/  /, ' ');
                    var valArr = val.split(' ');
                    metadata[key] = { string: valArr };
                }
            }
        }
    });

    return metadata;
};

// Validate fields and display warnings
function validateFields() {
    // Get our validation groups
    var messages = [];
    var groups = buildValidationGroups();
    Object.values(groups).forEach(function (fields) {
        if (!isGroupValid(fields)) {
            var fieldNames = fields.map(function (field) {
                return fieldmap[field].label;
            });
            messages.push(
                "You must complete at least one of the following fields: " + fieldNames.join(', ')
            );
        }
    });
    // Handle fields that aren't in groups
    notEmpty.forEach(function (key) {
        var inpVal = $('#' + key).val();
        if (!inpVal || inpVal.length === 0) {
            var name = $('body').find('label[for="' + key + '"]').text().replace(/:/, '');
            messages.push(
                '"' + name + '" cannot be empty'
            );
        }
    });
    manageWarning(messages);
    manageSubmit(messages);
    debounce(requestability, 1000)(messages);
};