[% cwd = whole.cwd _ '/RapidILL' %]

<h2>Edit request</h2>
<form method="POST" action="[% here %]" id="edit_form">
  <fieldset class="rows">
    <legend>Edit metadata</legend>
    <input name="illrequest_id" value="[% whole.value.other.illrequest_id %]" type="hidden" />
    <input name="stage" id="stage" value="form" type="hidden"/>
    <input name="method" id="method" value="edititem" type="hidden"/>
    <input name="backend" id="backend" value="RapidILL" type="hidden"/>
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
  <fieldset class="action">
    <input id="update_submit" type="submit" value="Update"/>
    <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
  </fieldset>
</form>

<script>
    document.addEventListener('DOMContentLoaded', function(){
        var listenerSelectors = '';

        var fieldmap = [% whole.field_map_json %];
        addLabels();
        showFields();

        // Handle the "type" being changed
        $('#type').change(function() {
          if ($('#change_type').length > 0) {
            return;
          }
          $('#edit_form').prepend(
            '<input id="change_type" type="hidden" name="change_type" value="1" />'
          );
          $('#edit_form').submit();
        });

        [% INCLUDE "${cwd}/shared-includes/create.js" %]
    });
    //]]>
</script>