[% USE Koha %]
[% USE Asset %]
[% USE raw %]

[% IF whole.error %]
  [% IF whole.status == 'missing_fields' %]
    <p><em>Please Note:</em> Some mandatory fields are missing.</p>
  [% ELSIF whole.status == 'missing_branch' %]
    <p><em>Please Note:</em> Branch is a mandatory field.</p>
  [% ELSIF whole.status == 'invalid_borrower' %]
    <p><em>Please Note:</em> The borrower details you entered are invalid.</p>
  [% ELSIF whole.status == 'invalid_branch' %]
    <p><em>Please Note:</em> The branch you chose is invalid.</p>
  [% ELSIF whole.status == 'api' %]
    <p><em>Please Note:</em> there was an error whilst communicating with the remote service.</p>
  [% ELSIF whole.status == 'missing_query' %]
    <p><em>Please Note:</em> You did not enter a search query.</p>
  [% ELSIF whole.message %]
    <p><em>[% whole.message %]</em></p>
  [% ELSE %]
    <p><em>Unhandled error</em></p>
  [% END %]
[% END %]

[% IF whole.stage == "commit" %]
<p>We have now created your request.</p>

[% ELSIF whole.stage == "init" %]
<div role="alert" class="alert alert-warning" id="request-lookup" style="display: none">
  Checking item availability via RapidILL
  <img src="[% interface | html %]/[% theme | html %]/img/spinner-small.gif" alt="" />
</div>
<div role="alert" class="alert alert-success" id="request-possible" style="display: none">Item is available for request</div>
<div role="alert" class="alert alert-warning" id="request-notpossible" style="display: none">Item is not available for request</div>
<form method="POST" action="[% here %]" id="create_form">
  <fieldset class="rows">
    <legend>Enter metadata</legend>
    <input name="stage" id="stage" value="validate" type="hidden"/>
    <input name="method" id="method" value="create" type="hidden"/>
    <input name="backend" id="backend" value="[% whole.value.other.backend %]" type="hidden"/>
    <ol>
      [% FOREACH field IN whole.field_map.keys.sort %]
      [% IF !whole.field_map.$field.exclude %]
      <li id="rapid_field_[% field %]">
        <label for="[% field %]">[% whole.field_map.$field.label %]:</label>
        <input type="text" name="[% field %]" id="[% field %]" value="[% whole.value.other.$field %]" />
        [% IF whole.field_map.$field.help %]
        ([% whole.field_map.$field.help %])
        [% END %]
      </li>
      [% END %]
      [% END %]
      <li>
        <label for="RapidRequestType">Type:</label>
        <select name="RapidRequestType" id="type">
          [% options = { Book => 'Book', Article => 'Article', BookChapter => 'Book chapter' } %]
          [% FOREACH opt IN options.keys.sort %]
          [% IF ( whole.value.other.type == opt ) %]
          <option value="[% opt %]" selected="selected">[% options.$opt %]</option>
          [% ELSE %]
          <option value="[% opt %]">[% options.$opt %]</option>
          [% END %]
          [% END %]
        </select>
      </li>
    </ol>
  </fieldset>
  <fieldset class="rows">
    <legend>Patron options</legend>
    <ol>
      <li>
        <label class="required" for="cardnumber">Card number, username or surname:</label>
        <input type="text" autocomplete="off" name="cardnumber" id="cardnumber" type="text"
           value="[% whole.value.other.cardnumber %]" />
      </li>
      <li>
        <label class="required" for="branchcode">Destination library:</label>
        <select id="branchcode" name="branchcode">
          [% FOREACH branch IN branches %]
          [% IF ( whole.value.other.branchcode == branch.branchcode ) %]
          <option value="[% branch.branchcode %]" selected="selected">[% branch.branchname %]</option>
          [% ELSE %]
          <option value="[% branch.branchcode %]">[% branch.branchname %]</option>
          [% END %]
          [% END %]
        </select>
      </li>
    </ol>
  </fieldset>
  <fieldset class="action">
    <p id="rapid_warning" role="alert" class="alert alert-danger" style="visibility:hidden;"></p>
    <input id="rapid_submit" disabled type="submit" value="Make request"/>
    <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
  </fieldset>
</form>

[% END %]
<style>
  #rapid_warnings {
    margin-bottom: 0;
  }
  .rapid_hint {
   margin-left: 1em; 
  }
  .alert {
    margin-top: 20px;
  }
</style>
<script>
    // Require a username and branch selection
    document.addEventListener('DOMContentLoaded', function(){
        var listenerSelectors = '';
        var fieldmap = [% whole.field_map_json %];
        // Fields that are not in groups, but cannot be empty
        var notEmpty = [ 'cardnumber' ];
        showFields();
        validateFields();
        addHandlers();
        $('#type').change(function() {
          showFields();
          validateFields();
          addHandlers();
        });

        // Show or hide fields depending on selected type
        function showFields() {
          var selected = $('#type').val();
          Object.keys(fieldmap).forEach(function(key) {
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
          Object.keys(fieldmap).forEach(function(field) {
            if (fieldmap[field].required) {
              var req = fieldmap[field].required;
              Object.keys(req).forEach(function(material) {
                if (material === $('#type').val()) {
                  if (!groups[req[material].group]) {
                    groups[req[material].group] = [ field ];
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
          var filtered = fields.filter(function(field) {
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
            var listItems = messages.map(function(message) {
              return "<li>" + message + "</li>";
            });
            var content = '<ul id="rapid_warnings">' + listItems.join('') + "</ul>"
            warning.empty();
            warning.append(content);
            warning.css('visibility', 'visible');
          }
        };

        // Enable / disable submit button based on validation
        function manageSubmit(messages) {
          $("#rapid_submit").attr('disabled', messages.length > 0);
        }

        // Add event handlers for fields that need them
        function addHandlers() {
          var handleMe = [];
          Object.keys(fieldmap).forEach(function(field) {
            if (fieldmap[field].required && $("#" + field).is(':visible')) {
              handleMe.push("#rapid_field_" + field + " input");
            }
          });
          // Add the fields that cannot be empty
          handleMe = handleMe.concat(notEmpty.map(function(ne) {
            return '#' + ne;
          }));
          if (handleMe.length > 0) {
            var selectors = handleMe.join(',');

            // Remove pre-existing handlers
            if (listenerSelectors.length > 0) {
              $(selectors).off('keyup')
            }

            $(selectors).on('keyup', function() {
              validateFields();
              listenerSelectors = selectors;
            });
          }
        };

        // Check if something can be requested based on the current metadata
        function canRequestLookup(messages) {
          if (messages.length > 0) return;

          var baseMetadata = {
              IsHoldingsCheckOnly: true,
              DoBlockLocalOnly: false,
              PatronNotes: 'HOLDING_CHECK_DO_REMOTE_SEARCH'
          };

          // Merge our provided metadata, if appropriate
          var providedMetadata = gatherMetadata();
          // If we don't have any, we can't continue;
          if (Object.keys(providedMetadata).length === 0) return;
          var metadata = Object.assign(baseMetadata, providedMetadata);

          // Make the lookup call
          debouncedApiCall(
            'insertrequest',
            { metadata: metadata, borrowerId: 0},
            handleLookupResponse
          )();
        };

        // Return a debounced API call
        function debouncedApiCall(endpoint, data, callback) {
          return debounce(function() {
            $('#request-possible').css('display', 'none');
            $('#request-notpossible').css('display', 'none');
            $('#request-lookup').css('display', 'block');
            $.post({
              url: '/api/v1/contrib/rapidill/' + endpoint,
              data: JSON.stringify(data),
              contentType: 'application/json'
            })
              .done(function(resp, status) {
                callback(resp);
              })
          }, 1000);
        };

        // Simple debounce
        // Returns a function, that, as long as it continues to be invoked, will not
        // be triggered. The function will be called after it stops being called for
        // N milliseconds. If `immediate` is passed, trigger the function on the
        // leading edge, instead of the trailing.
        // Taken from: https://davidwalsh.name/javascript-debounce-function
        var timeout;
        function debounce(func, wait, immediate) {
          return function() {
            var context = this,
              args = arguments;
            var later = function() {
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
        function handleLookupResponse(response) {
          $('#request-lookup').css('display', 'none');
          $('#request-possible').css('display', 'none');
          $('#request-notpossible').css('display', 'none');
          if (response.result.FoundMatch === 1 && response.result.NumberOfAvailableHoldings > 0) {
            $('#request-possible').css('display', 'block');
          } else if (response.result.FoundMatch === 0) {
            $('#request-notpossible').css('display', 'block');
          }
        };

        // Iterate our fields for this material type and gather any provided values
        function gatherMetadata() {
          var type = $('#type').val();

          var metadata = {
            RapidRequestType: type
          };

          Object.keys(fieldmap).filter(function(key) {
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
          Object.values(groups).forEach(function(fields) {
            if (!isGroupValid(fields)) {
              var fieldNames = fields.map(function(field) {
                return fieldmap[field].label;
              });
              messages.push(
                "You must complete at least one of the following fields: " + fieldNames.join(', ')
              );
            }
          });
          // Handle fields that aren't in groups
          var invalid = [];
          notEmpty.forEach(function(key) {
            var inpVal = $('#' + key).val();
            if (!inpVal || inpVal.length === 0) {
                var name = $('body').find('label[for="' + key + '"]').text().replace(/:/,'');
                messages.push(
                  '"' + name + '" cannot be empty'
                );
            }
          });
          manageWarning(messages);
          manageSubmit(messages);
          canRequestLookup(messages);
        };

        // Add autocomplete for patron selection
        $('#create_form #cardnumber').autocomplete({
            source: "/cgi-bin/koha/circ/ysearch.pl",
            minLength: 3,
            select: function( event, ui ) {
                var field = ui.item.cardnumber;
                $('#create_form #cardnumber').val(field)
                return false;
            }
        })
        .data( "ui-autocomplete" )._renderItem = function( ul, item ) {
            return $( "<li></li>" )
            .data( "ui-autocomplete-item", item )
            .append( "<a>" + item.surname + ", " + item.firstname + " (" + item.cardnumber + ") <small>" + item.address + " " + item.city + " " + item.zipcode + " " + item.country + "</small></a>" )
            .appendTo( ul );
        };
    });
    //]]>
</script>