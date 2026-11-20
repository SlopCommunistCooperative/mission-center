/* first_run_dialog.rs
 *
 * Copyright 2026 Mission Center Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

use std::cell::{Cell, OnceCell};

use adw::prelude::AdwDialogExt;
use adw::subclass::prelude::*;

use gtk::prelude::{ActionMapExt, ButtonExt, DisplayExt, ObjectExt, WidgetExt};
use gtk::{
    gio,
    glib::{self, g_critical, g_warning},
    AlertDialog,
};

use crate::i18n::{i18n, i18n_f};
use crate::magpie_client::{ScriptName, ScriptRunResult};
use crate::{app, is_snap, MissionCenterWindow};

thread_local! {
    static ACTIVE_DIALOG: glib::WeakRef<FirstRunDialog> = glib::WeakRef::new();
    static SCRIPT_RUNNING: Cell<bool> = const { Cell::new(false) };
}

mod imp {
    use super::*;

    #[derive(gtk::CompositeTemplate, Default)]
    #[template(resource = "/io/missioncenter/MissionCenter/ui/first_run_dialog.ui")]
    pub struct FirstRunDialog {
        #[template_child]
        pub close: TemplateChild<gtk::Button>,
        #[template_child]
        pub run_script: TemplateChild<adw::SplitButton>,
        #[template_child]
        pub spinner: TemplateChild<adw::Spinner>,
        #[template_child]
        pub rapl_warning: TemplateChild<gtk::Label>,
        #[template_child]
        pub notice: TemplateChild<gtk::Label>,

        pub run_actions: OnceCell<[gio::SimpleAction; 2]>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FirstRunDialog {
        const NAME: &'static str = "FirstRunDialog";
        type Type = super::FirstRunDialog;
        type ParentType = adw::Dialog;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for FirstRunDialog {
        fn constructed(&self) {
            self.parent_constructed();
        }
    }

    impl WidgetImpl for FirstRunDialog {
        fn realize(&self) {
            self.parent_realize();
        }
    }

    impl AdwDialogImpl for FirstRunDialog {
        fn closed(&self) {}
    }
}

glib::wrapper! {
    pub struct FirstRunDialog(ObjectSubclass<imp::FirstRunDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl FirstRunDialog {
    pub fn new() -> Self {
        let this: Self = glib::Object::builder()
            .property("follows-content-size", true)
            .build();

        let imp = this.imp();

        let dialog = this.downgrade();
        imp.close.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.close();
            }
        });

        this.connect_map(|dialog| {
            if let Some(widget) = dialog.default_widget() {
                dialog.set_focus(Some(&widget));
            }
        });

        this
    }

    pub fn run() {
        let app = app!();

        let Some(window) = app.window() else {
            g_critical!(
                "MissionCenter::FirstRunDialog",
                "No active window, when trying to show the first run dialog"
            );
            return;
        };

        let dialog = Self::new();

        if is_snap() {
            dialog.show_notice(&i18n(
                "Mission Center is installed as a Snap package, which runs in a sandbox that \
                 can't change system settings. Per-process network usage is unavailable in the \
                 Snap package. The wiki describes how to enable CPU power draw and fan readings \
                 on the host.",
            ));
        } else {
            let script = match app.sys_info() {
                Ok(magpie) => magpie.setup_script_name(),
                Err(_) => Err("Failed to get magpie client".to_owned()),
            };

            match script {
                Ok(script) => dialog.add_script_actions(script),
                Err(e) => {
                    g_warning!(
                        "MissionCenter::FirstRunDialog",
                        "The setup script is unavailable: {e}"
                    );
                    dialog.show_notice(&i18n_f("The additional setup is unavailable: {}", &[&e]));
                }
            }
        }

        dialog.set_busy(SCRIPT_RUNNING.get());
        ACTIVE_DIALOG.with(|active| active.set(Some(&dialog)));
        dialog.present(Some(&window));
    }

    pub fn script_finished(revert: bool, result: ScriptRunResult) {
        SCRIPT_RUNNING.set(false);

        let dialog = Self::active();
        if let Some(dialog) = &dialog {
            dialog.set_busy(false);
        }

        let Some(window) = app!().window() else {
            return;
        };

        let warning = match result {
            ScriptRunResult::Ok => None,
            ScriptRunResult::WithWarnings(warning) => Some(warning),
            ScriptRunResult::Err(message) => {
                Self::show_failure(&window, revert, message);
                return;
            }
        };

        if let Some(dialog) = dialog {
            dialog.close();
        }
        if revert {
            Self::show_revert_notice(&window);
        } else {
            Self::offer_restart(&window, warning);
        }
    }

    fn active() -> Option<Self> {
        ACTIVE_DIALOG.with(|active| active.upgrade())
    }

    fn add_script_actions(&self, script: ScriptName) {
        let ScriptName {
            file,
            command,
            revert_command,
        } = script;

        let group = gio::SimpleActionGroup::new();

        let run = gio::SimpleAction::new("run", None);
        run.connect_activate(|_, _| Self::start_script(false));
        group.add_action(&run);

        let revert = gio::SimpleAction::new("revert", None);
        revert.connect_activate(|_, _| Self::start_script(true));
        group.add_action(&revert);

        let action = gio::SimpleAction::new("view", None);
        let view_file = file.clone();
        action.connect_activate(move |_, _| Self::view_script(&view_file));
        group.add_action(&action);

        let display = WidgetExt::display(self);
        for (name, text) in [
            ("copy-location", file),
            ("copy-command", command),
            ("copy-revert-command", revert_command),
        ] {
            let action = gio::SimpleAction::new(name, None);
            let display = display.clone();
            action.connect_activate(move |_, _| display.clipboard().set_text(&text));
            group.add_action(&action);
        }

        self.insert_action_group("setup", Some(&group));
        let _ = self.imp().run_actions.set([run, revert]);
    }

    fn show_notice(&self, text: &str) {
        let imp = self.imp();

        imp.notice.set_label(text);
        imp.notice.set_visible(true);
        imp.rapl_warning.set_visible(false);
        imp.run_script.set_visible(false);
        self.set_default_widget(Some(&*imp.close));
    }

    fn set_busy(&self, busy: bool) {
        let imp = self.imp();

        imp.spinner.set_visible(busy);
        for action in imp.run_actions.get().into_iter().flatten() {
            action.set_enabled(!busy);
        }
    }

    fn start_script(revert: bool) {
        if SCRIPT_RUNNING.get() {
            return;
        }

        let started = match app!().sys_info() {
            Ok(magpie) => magpie.setup_script_run(revert),
            Err(_) => Err("Failed to get magpie client".to_owned()),
        };

        match started {
            Ok(()) => {
                SCRIPT_RUNNING.set(true);
                if let Some(dialog) = Self::active() {
                    dialog.set_busy(true);
                }
            }
            Err(e) => Self::script_finished(revert, ScriptRunResult::Err(e)),
        }
    }

    fn view_script(file: &str) {
        let opened = match app!().sys_info() {
            Ok(magpie) => magpie.setup_script_open(),
            Err(_) => Err("Failed to get magpie client".to_owned()),
        };
        let Err(message) = opened else {
            return;
        };

        let Some(window) = app!().window() else {
            return;
        };

        let error_dialog = AlertDialog::builder()
            .modal(true)
            .message(i18n("Failed to Open Script"))
            .detail(format!("{file}:\n{message}"))
            .default_button(1)
            .buttons([i18n("Copy File Location"), i18n("Close")])
            .build();

        let display = WidgetExt::display(&window);
        let file = file.to_owned();
        error_dialog.choose(Some(&window), None::<&gio::Cancellable>, move |response| {
            if let Ok(0) = response {
                display.clipboard().set_text(&file);
            }
        });
    }

    fn show_revert_notice(window: &MissionCenterWindow) {
        AlertDialog::builder()
            .modal(true)
            .message(i18n("Additional Setup Reverted"))
            .detail(i18n(
                "Restart your computer at your earliest convenience to fully revert the changes.",
            ))
            .buttons([i18n("Close")])
            .build()
            .show(Some(window));
    }

    fn offer_restart(window: &MissionCenterWindow, warning: Option<String>) {
        let restart = i18n("Restart Mission Center to apply changes?");
        let (message, detail) = match warning {
            None => (i18n("Success!"), restart),
            Some(warning) => (
                i18n("Setup Finished With Warnings"),
                format!("{warning}\n\n{restart}"),
            ),
        };

        let restart_dialog = AlertDialog::builder()
            .modal(true)
            .message(message)
            .detail(detail)
            .buttons([i18n("Restart"), i18n("Close")])
            .build();

        restart_dialog.choose(Some(window), None::<&gio::Cancellable>, |response| {
            if let Ok(0) = response {
                app!().restart();
            }
        });
    }

    fn show_failure(window: &MissionCenterWindow, revert: bool, message: String) {
        let title = if revert {
            i18n("Revert Setup Script Failed")
        } else {
            i18n("Setup Script Failed")
        };

        let error_dialog = AlertDialog::builder()
            .modal(true)
            .message(title)
            .detail(&message)
            .buttons([i18n("Copy Output"), i18n("Retry"), i18n("Close")])
            .default_button(1)
            .build();

        let display = WidgetExt::display(window);
        error_dialog.choose(
            Some(window),
            None::<&gio::Cancellable>,
            move |response| match response {
                Ok(0) => display.clipboard().set_text(&message),
                Ok(1) => Self::start_script(revert),
                _ => {}
            },
        );
    }
}
