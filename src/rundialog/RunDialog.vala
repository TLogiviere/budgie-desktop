/*
 * This file is part of budgie-desktop
 *
 * Copyright © 2015-2018 Budgie Desktop Developers
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

namespace Budgie {

/**
 * We need to probe the dbus daemon directly, hence this interface
 */
[DBus (name="org.freedesktop.DBus")]
public interface DBusImpl : Object
{
    public abstract async string[] list_names() throws GLib.DBusError, GLib.IOError;
    public signal void name_owner_changed(string name, string old_owner, string new_owner);
}

/**
 * Simple launcher button
 */
public class AppLauncherButton : Gtk.Box
{
    public AppInfo? app_info = null;
    public string? bname;
    public string? bdesc;

    public AppLauncherButton(AppInfo? info)
    {
        Object(orientation: Gtk.Orientation.HORIZONTAL);
        this.app_info = info;

        get_style_context().add_class("launcher-button");
        var image = new Gtk.Image.from_gicon(info.get_icon(), Gtk.IconSize.DIALOG);
        image.pixel_size = 48;
        image.set_margin_start(8);
        pack_start(image, false, false, 0);
        this.bname = Markup.escape_text(info.get_name());
        if (bname == null)
            bname = "";
        this.bdesc = info.get_description();
        if (bdesc == null)
            bdesc = "";
        else
            bdesc = Markup.escape_text(bdesc);
        var label = new Gtk.Label("<big>%s</big>\n<small>%s</small>".printf(bname, bdesc));
        label.get_style_context().add_class("dim-label");
        label.set_line_wrap(true);
        label.set_property("xalign", 0.0);
        label.use_markup = true;
        label.set_margin_start(12);
        label.set_max_width_chars(60);
        label.set_halign(Gtk.Align.START);
        pack_start(label, false, false, 0);

        set_hexpand(false);
        set_vexpand(false);
        set_halign(Gtk.Align.START);
        set_valign(Gtk.Align.START);
        set_tooltip_text(bname);
        set_margin_top(3);
        set_margin_bottom(3);
    }
}

/**
 * The meat of the operation
 */
public class RunDialog : Gtk.ApplicationWindow
{

    Gtk.Box? main_layout;
    Gtk.Revealer bottom_revealer;
    public Gtk.ListBox? app_box;
    Gtk.SearchEntry entry;
    Budgie.ThemeManager theme_manager;
    Gdk.AppLaunchContext context;
    bool focus_quit = true;
    DBusImpl? impl = null;
    Gtk.ListBoxRow? first_revealed_row;

    string search_text = "";

    /* The .desktop file without the .desktop */
    string wanted_dbus_id = "";

    /* Active dbus names */
    HashTable<string,bool> active_names = null;

    public RunDialog(Gtk.Application app)
    {
        Object(application: app);
        set_keep_above(true);
        set_skip_pager_hint(true);
        set_skip_taskbar_hint(true);

        set_position(Gtk.WindowPosition.CENTER);

        Gdk.Visual? visual = screen.get_rgba_visual();
        if (visual != null) {
            set_visual(visual);
        }

        /* Quicker than a list lookup */
        this.active_names = new HashTable<string,bool>(str_hash, str_equal);

        this.context = get_display().get_app_launch_context();
        context.launched.connect(on_launched);
        context.launch_failed.connect(on_launch_failed);

        /* Handle all theme management */
        this.theme_manager = new Budgie.ThemeManager();

        Gtk.EventBox header = new Gtk.EventBox();
        set_titlebar(header);
        header.get_style_context().remove_class("titlebar");

        get_style_context().add_class("budgie-run-dialog");

        /* KEY EVENT */
        key_release_event.connect(on_key_release);

        this.main_layout = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        add(main_layout);
        /* Main layout, just a hbox with search-as-you-type */
        Gtk.Box hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        main_layout.pack_start(hbox, false, false, 0);

        this.entry = new Gtk.SearchEntry();
        entry.set_placeholder_text("Type to search an app…");
        entry.set_icon_from_icon_name (Gtk.EntryIconPosition.SECONDARY, "view-list-symbolic");
        entry.set_icon_sensitive(Gtk.EntryIconPosition.SECONDARY, true);
        stderr.printf(this.entry.get_icon_name(Gtk.EntryIconPosition.PRIMARY).to_string());
        entry.icon_press.connect ((pos, event) => {
            if (pos == Gtk.EntryIconPosition.SECONDARY) {
                toggle_bottom_revealer();
            }
        });
        /* changed -> search_changed
         * So filtering is not spun up uselessly, e.g. char 3,4 are useless while
         * char 5 permit to increase the filtering as per the doc.
         * Still, reacting to event "changed" makes the search feels more reactive… ?_?
         */
        this.entry.changed.connect(() => {
            this.search_text = entry.text;
            on_search_changed();
        });
        this.entry.activate.connect(on_search_activate);
        this.entry.get_style_context().set_junction_sides(Gtk.JunctionSides.BOTTOM);

        hbox.pack_start(entry, true, true, 0);

        this.bottom_revealer = new Gtk.Revealer();
        main_layout.pack_start(bottom_revealer, true, true, 0);

        this.app_box = new Gtk.ListBox();
        app_box.set_selection_mode(Gtk.SelectionMode.SINGLE);
        app_box.set_activate_on_single_click(true);
        app_box.row_activated.connect(on_row_activate);
        app_box.set_filter_func(this.filter_fn);
        app_box.set_sort_func(this.sort_fn);

        Gtk.ScrolledWindow scroll = new Gtk.ScrolledWindow(null, null);
        scroll.get_style_context().set_junction_sides(Gtk.JunctionSides.TOP);
        scroll.set_size_request(-1, 300);
        scroll.add(app_box);
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

        this.bottom_revealer.add(scroll);
        /* Just so I can debug for now = false
         * false: hide the filter result area when the tool is started
         * true: you know it…
         */
        bottom_revealer.set_reveal_child(false);

        Idle.add(()=>{
            set_icon_tooltip();
            return false;
            });

        set_size_request(420, -1);
        set_default_size(420, -1);
        set_border_width(0);
        set_resizable(false);

        focus_out_event.connect(()=> {
            if (!this.focus_quit) {
                return Gdk.EVENT_STOP;
            }
            this.application.quit();
            return Gdk.EVENT_STOP;
        });

        //add_events(Gdk.EventMask.KEY_PRESS_MASK);
        key_press_event.connect((event) => {
            if (event.keyval == Gdk.Key.Up) {
                if (!this.entry.has_focus){
                    var index_first = this.first_revealed_row.get_index();
                    var index_selected = this.app_box.get_selected_row().get_index();
                    if (index_first == index_selected){
                        this.entry.grab_focus_without_selecting();
                        return true;
                    }
                }
                return false;
            } else if (event.keyval == Gdk.Key.Down || event.keyval == Gdk.Key.Page_Up || event.keyval == Gdk.Key.Page_Down) {
                if (this.first_revealed_row != null){
                    if (this.entry.has_focus)
                        this.first_revealed_row.grab_focus();
                    }
                return false;
            // Other keys but Escape
            } else if (event.keyval != Gdk.Key.Escape){
                if (!this.entry.has_focus)
                    this.entry.grab_focus_without_selecting();
                return false;
            }
            return false;
        });

        main_layout.show_all();
    }

    void set_icon_tooltip(){
        if (this.bottom_revealer.get_reveal_child())
            this.entry.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, "Hide the list");
        else
            this.entry.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, "Show all apps");
    }
    void toggle_bottom_revealer() {
        if (this.bottom_revealer.get_reveal_child()) {
            bottom_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
            bottom_revealer.set_reveal_child(false);
        } else {
            bottom_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN);
            bottom_revealer.set_reveal_child(true);
        }
        set_icon_tooltip();
    }
    /**
     * Handle click/<enter> activation on the main list
     */
    void on_row_activate(Gtk.ListBoxRow row)
    {
        activate_row(row);
    }

    /**
     * Handle <enter> activation on the search
     */
    void on_search_activate()
    {
        // null check is mandatory to prevent spitting "assertion 'selected_row != NULL' failed"
        var selected_row = this.app_box.get_selected_row();
        if (selected_row != null){
            activate_row(selected_row);
        }
    }

    void activate_row(Gtk.ListBoxRow row)
    {
        launch_button((row as Gtk.Bin).get_child() as AppLauncherButton);
    }

    /**
     * Launch the given preconfigured button
     */
    void launch_button(AppLauncherButton button)
    {
        try {
            DesktopAppInfo dinfo = button.app_info as DesktopAppInfo;

            this.context.set_screen(get_screen());
            context.set_timestamp(Gdk.CURRENT_TIME);
            this.focus_quit = false;
            string[] splits = dinfo.get_id().split(".desktop");
            if (dinfo.get_boolean("DBusActivatable")) {
                this.wanted_dbus_id = string.joinv(".desktop", splits[0:splits.length-1]);
            }
            dinfo.launch(null, context);
            check_dbus_name();
            // Some apps are slow to open so hide and quit when they're done
            hide();
        } catch (Error e) {
            this.application.quit();
        }
    }

    void on_search_changed()
    {
        // Setting the string used in the filter function
        this.search_text = entry.get_text().down();
        // Updating the result area (ListBox)
        this.app_box.invalidate_filter();
        /* We don't sort the buttons if the search entry is empty
         * but it could be better to sort by alphabetical order.
         */
        if (this.search_text != "")
            this.app_box.invalidate_sort();

        this.first_revealed_row = null;
        foreach (var row in this.app_box.get_children()) {
                /*
                 * row.get_visible() is insufficient but row.get_child_visible() is not.
                 */
                if (row.get_child_visible()) {
                    // We keep memory of the first ListBoxRow matching the search
                    this.first_revealed_row = row as Gtk.ListBoxRow;
                    break;
                }
            }
        // If at least one app_info match the search
        if (this.first_revealed_row != null) {
            // If the text entry is not empty (e.g. when the user clears it)
            if (this.search_text != "") {
                //this.app_box.invalidate_sort();
                /*var selected_row = this.app_box.get_selected_row();
                if (selected_row == null || !selected_row.get_child_visible())*/
                    this.app_box.select_row(this.first_revealed_row);
                    //this.app_box.selected_rows_changed();
                    //this.first_revealed_row.grab_focus();
            } else {
                /* Unsucessful attempt at displaying the show/hide app list icon when the search is cleared.
                 */

                /*this.entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY, "view-list-symbolic");
                this.entry.set_icon_activatable(Gtk.EntryIconPosition.SECONDARY, true);
                this.entry.set_icon_sensitive(Gtk.EntryIconPosition.SECONDARY, true);
                this.entry.set_visibility(true);
                this.entry.show_all();
                */

                /* Unselect previously selected row(s) so we keep lag out of user critical input
                 * (launching of an app) by just checking for null in on_search_activate.
                 * Plus, when there is nothing to do, a bit more processing does not matter.
                 */
                this.app_box.unselect_all();
                //this.app_box.unselect_row(this.app_box.get_selected_row());
            }
            // We display the widget containing (the widget containing) the list of app
            if (!this.bottom_revealer.get_reveal_child()) {
                toggle_bottom_revealer();
            }
        // If no app_info match the search
        } else {
            if (this.bottom_revealer.get_reveal_child()) {
                toggle_bottom_revealer();
            }
            /* Unselect previously selected row(s) so we keep lag out of user critical input
                 * (launching of an app) by just checking for null in on_search_activate.
                 * Plus, when there is no result to show, a bit more processing does not matter.
                 */
            this.app_box.unselect_all();
            //this.app_box.unselect_row(this.app_box.get_selected_row());
            //this.first_revealed_row = null;
        }
    }

    /**
     * Filter and sort the list
     * We filter based on every information string we have but sort only with 'human' informative ones (display_name, exec_name, description)
     * as some app can have non informative name but informative display_name e.g : gufw name is ghbbutton but display name is firewall configuration.
     * By doing so, we provide the most user-friendly sort.
     */
    bool filter_fn(Gtk.ListBoxRow row)
    {
        AppLauncherButton button = row.get_child() as AppLauncherButton;

        if (this.search_text == "") {
            /* true : Let all the apps match when the search string is empty
             * false : you know it…
             */
            return true;
        }

        // Ported across from budgie menu
        string? app_name, exec;

        app_name = button.app_info.get_display_name();
        if (app_name != null)
            app_name = app_name.down();
        else
            app_name = "";
        exec = button.app_info.get_executable();
        if (exec != null)
            exec = exec.down();
        else
            exec = "";
        //stderr.printf("button name: "+button.bname+"app name: "+app_name+"button desc: "+button.bdesc+"exec name: "+exec);
        return (search_text in app_name || search_text in button.bdesc || search_text in exec);
    }

    int sort_fn(Gtk.ListBoxRow row1, Gtk.ListBoxRow row2){
        var btn1 = row1.get_child() as AppLauncherButton;
        if (this.search_text in btn1.app_info.get_display_name().down())// || this.search_text in btn1.app_info.get_executable().down())
            return -1;
        else {
            var btn2 = row2.get_child() as AppLauncherButton;
            if (this.search_text in btn2.app_info.get_display_name().down())// || this.search_text in btn2.app_info.get_executable().down())
                return 1;
            else {
                if (this.search_text in btn1.bdesc)
                    return -1;
                else if(this.search_text in btn2.bdesc)
                    return 1;
                return 0;
            }
        }
    }

    /**
     * Be a good citizen and pretend to be a dialog.
     */
    bool on_key_release(Gdk.EventKey btn)
    {
        if (btn.keyval == Gdk.Key.Escape) {
            Idle.add(()=> {
                this.application.quit();
                return false;
            });
            return Gdk.EVENT_STOP;
        }
        return Gdk.EVENT_PROPAGATE;
    }

    /**
     * Handle startup notification, mark it done, quit
     * We may not get the ID but we'll be told it's launched
     */
    private void on_launched(GLib.AppInfo info, Variant v)
    {
        Variant? elem;

        var iter = v.iterator();

        while ((elem = iter.next_value()) != null) {
            string? key = null;
            Variant? val = null;

            elem.get("{sv}", out key, out val);

            if (key == null) {
                continue;
            }

            if (!val.is_of_type(VariantType.STRING)) {
                continue;
            }

            if (key != "startup-notification-id") {
                continue;
            }
            get_display().notify_startup_complete(val.get_string());
        }
        this.application.quit();
    }

    /**
     * Set the ID if it exists, quit regardless
     */
    private void on_launch_failed(string id)
    {
        get_display().notify_startup_complete(id);
        this.application.quit();
    }


    void on_name_owner_changed(string? n, string? o, string? ne)
    {
        if (o == "") {
            this.active_names[n] = true;
            check_dbus_name();
        } else {
            if (n in this.active_names) {
                active_names.remove(n);
            }
        }
    }

    /**
     * Check if our dbus name appeared. if it did, bugger off.
     */
    void check_dbus_name() {
        if (this.wanted_dbus_id != "" && this.wanted_dbus_id in this.active_names) {
            this.application.quit();
        }
    }

    /**
     * Do basic dbus initialisation
     */
    public async void setup_dbus()
    {
        try {
            impl = yield Bus.get_proxy(BusType.SESSION, "org.freedesktop.DBus", "/org/freedesktop/DBus");

            /* Cache the names already active */
            foreach (string name in yield impl.list_names()) {
                this.active_names[name] = true;
            }
            /* Watch for new names */
            impl.name_owner_changed.connect(on_name_owner_changed);
        } catch (Error e) {
            warning("Failed to initialise dbus: %s", e.message);
        }
    }
}

/**
 * GtkApplication for single instance wonderness
 */
public class RunDialogApp : Gtk.Application {

    private RunDialog? rd = null;

    public RunDialogApp()
    {
        Object(application_id: "org.budgie_desktop.BudgieRunDialog", flags: 0);
    }

    public override void activate()
    {
        if (this.rd == null) {
            rd = new RunDialog(this);

            // Do peripheral processing when main loop is idle so we spawn gui faster
            // See https://stackoverflow.com/questions/2151714/are-glib-signals-asynchronous#2152225
            Idle.add(()=>{
                populate_app_box();
                rd.setup_dbus.begin();
                return false; //Source.REMOVE = false
            });
            // Show the GUI
            rd.present();
        }
    }
    /**
     * Get all apps and instantiate an AppauncherButton for each
     * Called when main loop is idle.
     */
    public void populate_app_box()
    {
        List<AppInfo> apps_list = AppInfo.get_all();

        foreach (AppInfo app_info in apps_list){
            if (app_info.should_show()) {
                AppLauncherButton button = new AppLauncherButton(app_info);
                this.rd.app_box.add(button);
                button.show_all();
            }
        }
    }
}

} /* End namespace */

public static int main(string[] args)
{
    Intl.setlocale(LocaleCategory.ALL, "");
    Intl.bindtextdomain(Budgie.GETTEXT_PACKAGE, Budgie.LOCALEDIR);
    Intl.bind_textdomain_codeset(Budgie.GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain(Budgie.GETTEXT_PACKAGE);

    Budgie.RunDialogApp app = new Budgie.RunDialogApp();
    /* Blocking call */
    app.run(args);
    return 0;
}
