[% USE Koha %]
[% USE Asset %]
[% USE raw %]
[% SET koha_version = Koha.Version %]

[% cwd = whole.cwd _ '/RapidILL' %]

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
<div role="alert" class="alert alert-warning" id="request-notpossible" style="display: none">
  Item cannot be requested
  <div id="localholdings" style="display:none"></div>
  <div id="errormessage" style="display:none"></div>
</div>
<form method="POST" action="[% here %]" id="create_form">
  [% INCLUDE 'csrf-token.inc' %]
  <fieldset class="rows">
    <legend>Enter metadata</legend>
    <input name="stage" id="stage" value="validate" type="hidden"/>
    <input name="method" id="method" value="create" type="hidden"/>
    <input name="backend" id="backend" value="[% whole.value.other.backend %]" type="hidden"/>
    <ol>
      <li>
        <label for="RapidRequestType">Type:</label>
        <select name="RapidRequestType" id="type">
          [% options = { Book => 'Book', Article => 'Article', BookChapter => 'Book chapter' } %]
          [% FOREACH opt IN options.keys.sort %]
          [% IF ( whole.value.other.RapidRequestType == opt ) %]
          <option value="[% opt %]" selected="selected">[% options.$opt %]</option>
          [% ELSE %]
          <option value="[% opt %]">[% options.$opt %]</option>
          [% END %]
          [% END %]
        </select>
      </li>
      [% FOREACH field IN whole.field_map %]
      [% key = field.key %]
      [% IF !field.exclude %]
      <li id="rapid_field_[% key %]">
        <label id="[% key %]_label" for="[% key %]"></label>
        <input type="text" name="[% key %]" id="[% key %]" value="[% whole.value.other.$key %]" />
        [% IF field.help %]
        ([% field.help %])
        [% END %]
      </li>
      [% END %]
      [% END %]
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
  #localholdings,
  #errormessage {
    margin-top: 1rem;
  }
  #localholdings ul {
    margin-top: 0.5rem;
  }
  #localholdings li {
    margin: 0.3rem 0;
  }
</style>
[% BLOCK backend_jsinclude %]
<script>
  // Require a username and branch selection
  document.addEventListener('DOMContentLoaded', function(){
      // Fields that are not in groups, but cannot be empty
      var notEmpty = [ 'cardnumber' ];

      var listenerSelectors = '';

      var fieldmap = [% whole.field_map_json %];
      addLabels();
      showFields();
      validateFields();
      addHandlers();
      $('#type').change(function() {
          addLabels();
          showFields();
          validateFields();
          addHandlers();
      });

      [% INCLUDE "${cwd}/shared-includes/create.js" %]

      /* Maintain patron autocomplete compatibility across versions */
      [% IF koha_version.major <= 22 && koha_version.minor < 11 %]
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
      [% ELSE %]
      patron_autocomplete(
        $('#create_form #cardnumber'),
        {
          'on-select-callback': function( event, ui ) {
            $("#create_form #cardnumber").val( ui.item.cardnumber );
            return false;
          }
        }
      );
      [% END %]
  });
  //]]>
</script>
[% END %]
