<div class="info">{TR_INTRO}</div>

<!-- BDP: no_domains_block -->
<div class="static_info">{NO_DOMAINS}</div>
<!-- EDP: no_domains_block -->

<!-- BDP: domain_list -->
<form name="php_version" method="post" action="php_version.php">
    <table class="firstColFixed datatable">
        <thead>
        <tr>
            <th><input type="checkbox" id="php_version_all" title="{TR_SELECT_ALL}"></th>
            <th>{TR_STATUS}</th>
            <th>{TR_DOMAIN_NAME}</th>
            <th>{TR_DOMAIN_KIND}</th>
            <th>{TR_CURRENT}</th>
            <th>{TR_NEW_VERSION}</th>
        </tr>
        </thead>
        <tbody>
        <!-- BDP: domain_item -->
        <tr>
            <td><input type="checkbox" class="php_version_pick" value="{DOMAIN_KEY}"{ROW_DISABLED}></td>
            <td><div class="icon i_{STATUS_ICON}">{STATUS}</div></td>
            <td>{DOMAIN_NAME}</td>
            <td>{DOMAIN_KIND}</td>
            <td>{CURRENT_VERSION}</td>
            <td>
                <select name="version[{DOMAIN_KEY}]" data-key="{DOMAIN_KEY}"{ROW_DISABLED}>
                    {VERSION_OPTIONS}
                </select>
            </td>
        </tr>
        <!-- EDP: domain_item -->
        </tbody>
    </table>

    <div class="buttons">
        <label for="php_version_bulk">{TR_BULK_SET}</label>
        <select id="php_version_bulk">{BULK_OPTIONS}</select>
        <button type="button" id="php_version_bulk_apply">{TR_BULK_APPLY}</button>
        <input name="submit" type="submit" value="{TR_APPLY}">
    </div>
</form>

<script>
    (function ($) {
        // The per-row selects are what the form actually submits. The bulk
        // control is a convenience that fills them in, so a reseller or a
        // customer with many domains can set them all in one go and still see
        // exactly what is about to be submitted before pressing Apply.
        $("#php_version_all").on("change", function () {
            $(".php_version_pick:not(:disabled)").prop("checked", this.checked);
        });

        $("#php_version_bulk_apply").on("click", function () {
            var version = $("#php_version_bulk").val();

            $(".php_version_pick:checked").each(function () {
                $("select[data-key='" + $(this).val() + "']").val(version);
            });
        });
    })(jQuery);
</script>
<!-- EDP: domain_list -->
