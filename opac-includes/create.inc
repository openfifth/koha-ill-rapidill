[% USE Koha %]
[% IF whole.error %]
  [% IF whole.status == 'missing_fields' %]
    <p><em>Please Note:</em> Some mandatory fields are missing.</p>
  [% ELSIF whole.status == 'missing_branch' %]
    <p><em>Please Note:</em> Branch is a mandatory field.</p>
  [% ELSIF whole.status == 'invalid_borrower' %]
    <p><em>Please Note:</em> The borrower details you entered are invalid.</p>
  [% ELSIF whole.status == 'invalid_branch' %]
    <p><em>Please Note:</em> The branch you chose is invalid.</p>
  [% ELSIF whole.status == 'invalid_metadata' %]
    <p><em>Please Note:</em> You did not supply the correct metadata for the selected material type.</p>
  [% ELSIF whole.status == 'api' %]
    <p><em>Please Note:</em> there was an error whilst communicating with the remote service.</p>
  [% ELSIF whole.message %]
    <p><em>[% whole.message %]</em></p>
  [% ELSE %]
    <p><em>Unhandled error</em></p>
  [% END %]
[% END %]

[% IF whole.stage == "commit" %]
<p>We have now created your request.</p>

[% ELSIF whole.stage == "init" %]
<form method="POST">
  <fieldset class="rows">
    <legend>Place an interlibrary loan request</legend>
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
        <span class="rapid_hint">([% whole.field_map.$field.help %])</span>
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
        <label class="required" for="branchcode">Destination library:</label>
        <select id="branchcode" name="branchcode">
          <option value="" />
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
    <input id="rapid_submit" type="submit" value="Make request"/>
    <a class="cancel" href="/cgi-bin/koha/opac-illrequests.pl">Cancel</a>
  </fieldset>
</form>

[% BLOCK backend_jsinclude %]
<script>
  document.addEventListener('DOMContentLoaded', function(){
      var fieldmap = [% whole.field_map_json %];
      showFields();
      $('#type').change(function() {
        showFields();
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
  });
</script>
[% END %]

[% END %]
