"""FusionReader's separate SSH administration app; run or freeze with PyInstaller."""
from __future__ import annotations

import csv
from datetime import datetime
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from ssh_client import ConnectionSettings, RemoteManager, UnknownHost, safe_error


STATES = {'unused': '未使用', 'used': '已使用', 'expired': '已过期', 'revoked': '已撤销'}


def display_time(value):
    if not value:
        return '未知（旧版记录）'
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone().strftime('%Y-%m-%d %H:%M')
    except (ValueError, TypeError):
        return '—'


class ManagerApp:
    def __init__(self, root, remote=None):
        self.root = root
        self.remote = remote or RemoteManager()
        self.events = queue.Queue()
        self.busy = False
        self.connected = False
        self.closing = False
        self.buttons = []
        self.invites, self.users, self.generated = {}, {}, []
        self.invite_next = self.user_next = None
        root.title('聚阅 · 账号管理')
        root.geometry('1120x780')
        root.minsize(960, 680)
        root.protocol('WM_DELETE_WINDOW', self.close)
        style = ttk.Style(root)
        if 'vista' in style.theme_names():
            style.theme_use('vista')
        style.configure('TLabel', font=('Microsoft YaHei UI', 10))
        style.configure('TButton', font=('Microsoft YaHei UI', 10), padding=(10, 5))
        style.configure('Treeview', font=('Microsoft YaHei UI', 10), rowheight=30)
        style.configure('Treeview.Heading', font=('Microsoft YaHei UI', 10, 'bold'))
        style.configure('Title.TLabel', font=('Microsoft YaHei UI', 22, 'bold'), foreground='#263d68')
        container = ttk.Frame(root, padding=20)
        container.pack(fill='both', expand=True)
        ttk.Label(container, text='聚阅 · 账号管理', style='Title.TLabel').pack(anchor='w')
        ttk.Label(container, text='通过 SSH 连接服务器，管理激活码与用户。密码只用于本次连接。').pack(anchor='w', pady=(4, 14))
        self.connection_panel(container)
        self.tabs = ttk.Notebook(container)
        self.tabs.pack(fill='both', expand=True, pady=(14, 12))
        invite_tab = ttk.Frame(self.tabs, padding=12)
        user_tab = ttk.Frame(self.tabs, padding=12)
        self.tabs.add(invite_tab, text='  激活码  ')
        self.tabs.add(user_tab, text='  用户管理  ')
        self.invite_panel(invite_tab)
        self.user_panel(user_tab)
        self.status = tk.StringVar(value='未连接。服务器地址和凭据不会写入程序或自动保存。')
        ttk.Label(container, textvariable=self.status, foreground='#52617a', wraplength=1040).pack(anchor='w')
        self.update_buttons()

    def button(self, parent, label, command, *, connection=False, offline=False):
        button = ttk.Button(parent, text=label, command=command)
        self.buttons.append((button, connection, offline))
        return button

    def update_buttons(self):
        for button, connection, offline in self.buttons:
            allowed = not self.busy and (offline or (not self.connected if connection else self.connected))
            button.configure(state='normal' if allowed else 'disabled')
        for entry in self.connection_entries:
            entry.configure(state='disabled' if self.busy or self.connected else 'normal')

    def connection_panel(self, parent):
        frame = ttk.LabelFrame(parent, text='服务器连接', padding=12)
        frame.pack(fill='x')
        self.host, self.port = tk.StringVar(), tk.StringVar(value='22')
        self.username, self.password = tk.StringVar(value='root'), tk.StringVar()
        self.key = tk.StringVar()
        fields = [('IP 或域名', self.host, 27), ('SSH 端口', self.port, 6),
                  ('用户名', self.username, 10), ('密码 / 私钥口令', self.password, 22)]
        self.connection_entries = []
        for column, (label, value, width) in enumerate(fields):
            ttk.Label(frame, text=label).grid(row=0, column=column, sticky='w', padx=(0, 12))
            entry = ttk.Entry(frame, textvariable=value, width=width,
                              show='●' if value is self.password else '')
            entry.grid(row=1, column=column, sticky='ew', padx=(0, 12), pady=(4, 10))
            self.connection_entries.append(entry)
        self.button(frame, '连接', self.connect, connection=True).grid(row=1, column=4, padx=(0, 8))
        self.button(frame, '断开', self.disconnect).grid(row=1, column=5)
        ttk.Label(frame, text='私钥（选填）').grid(row=2, column=0, sticky='w')
        key_entry = ttk.Entry(frame, textvariable=self.key, width=65)
        key_entry.grid(row=3, column=0, columnspan=4, sticky='ew', padx=(0, 12), pady=(4, 0))
        self.connection_entries.append(key_entry)
        self.button(frame, '选择私钥', self.choose_key, connection=True).grid(row=3, column=4, columnspan=2, sticky='w')
        frame.columnconfigure(0, weight=1)

    def tree(self, parent, columns):
        frame = ttk.Frame(parent)
        frame.pack(fill='both', expand=True, pady=(10, 8))
        tree = ttk.Treeview(frame, columns=[name for name, _, _ in columns], show='headings', selectmode='browse')
        for name, label, width in columns:
            tree.heading(name, text=label)
            tree.column(name, width=width, minwidth=60, stretch=True)
        vertical = ttk.Scrollbar(frame, orient='vertical', command=tree.yview)
        horizontal = ttk.Scrollbar(frame, orient='horizontal', command=tree.xview)
        tree.configure(yscrollcommand=vertical.set, xscrollcommand=horizontal.set)
        tree.grid(row=0, column=0, sticky='nsew')
        vertical.grid(row=0, column=1, sticky='ns')
        horizontal.grid(row=1, column=0, sticky='ew')
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(0, weight=1)
        return tree

    def invite_panel(self, parent):
        bar = ttk.Frame(parent)
        bar.pack(fill='x')
        ttk.Label(bar, text='生成数量').pack(side='left')
        self.count = tk.StringVar(value='5')
        ttk.Spinbox(bar, from_=1, to=100, width=6, textvariable=self.count).pack(side='left', padx=(6, 16))
        ttk.Label(bar, text='有效天数').pack(side='left')
        self.days = tk.StringVar(value='30')
        ttk.Spinbox(bar, from_=1, to=365, width=6, textvariable=self.days).pack(side='left', padx=(6, 16))
        self.button(bar, '生成并入库', self.generate).pack(side='left')
        self.button(bar, '查看 / 导出本次生成', self.show_generated).pack(side='left', padx=8)
        self.button(bar, '刷新', self.refresh_invites).pack(side='right')
        ttk.Label(parent, text='列表显示管理编号，不显示原码。原码只在生成当次提供；关闭程序后只能粘贴原码查询。',
                  foreground='#52617a').pack(anchor='w', pady=(10, 0))
        self.invite_tree = self.tree(parent, [('id', '管理编号', 145), ('status', '状态', 80),
                                            ('user', '使用用户名', 110), ('created', '生成时间', 150),
                                            ('expires', '失效时间', 150), ('used', '使用时间', 150)])
        bottom = ttk.Frame(parent)
        bottom.pack(fill='x')
        self.query_code = tk.StringVar()
        ttk.Entry(bottom, textvariable=self.query_code, width=42).pack(side='left', padx=(0, 8))
        self.button(bottom, '查询原码', self.check_code).pack(side='left')
        self.button(bottom, '撤销选中的激活码', self.revoke_invite).pack(side='left', padx=8)
        self.button(bottom, '加载更多', lambda: self.refresh_invites(True)).pack(side='right')

    def user_panel(self, parent):
        bar = ttk.Frame(parent)
        bar.pack(fill='x')
        ttk.Label(bar, text='禁用、退出登录和重置密码均保留用户书架及历史。', foreground='#52617a').pack(side='left')
        self.button(bar, '刷新', self.refresh_users).pack(side='right')
        self.user_tree = self.tree(parent, [('username', '用户名', 160), ('state', '账号状态', 80),
                                          ('created', '注册时间', 160), ('favorites', '书架', 70),
                                          ('history', '历史', 70), ('sessions', '有效登录', 90),
                                          ('revision', '云端版本', 90)])
        bottom = ttk.Frame(parent)
        bottom.pack(fill='x')
        self.button(bottom, '禁用 / 启用', self.toggle_user).pack(side='left')
        self.button(bottom, '退出全部设备', self.revoke_sessions).pack(side='left', padx=8)
        self.button(bottom, '重置密码', self.reset_password).pack(side='left')
        self.button(bottom, '加载更多', lambda: self.refresh_users(True)).pack(side='right')

    def choose_key(self):
        path = filedialog.askopenfilename(title='选择 SSH 私钥', parent=self.root)
        if path:
            self.key.set(path)

    def run(self, title, operation, success, *, error=None):
        if self.busy:
            return
        self.busy = True
        self.status.set(title + '…')
        self.update_buttons()
        def worker():
            try:
                self.events.put((True, operation()))
            except Exception as exception:
                self.events.put((False, exception))
        threading.Thread(target=worker, daemon=True).start()
        def poll():
            if self.closing:
                return
            try:
                ok, result = self.events.get_nowait()
            except queue.Empty:
                self.root.after(80, poll)
                return
            self.busy = False
            self.update_buttons()
            if ok:
                success(result)
            elif error:
                error(result)
            else:
                self.status.set('操作未完成。若生成操作超时，请先刷新列表，避免重复生成。')
                messagebox.showerror('操作未完成', safe_error(result), parent=self.root)
        self.root.after(80, poll)

    def connect(self):
        try:
            settings = ConnectionSettings(self.host.get().strip(), int(self.port.get()),
                                          self.username.get().strip(), self.password.get(), self.key.get().strip())
            settings.validate()
        except Exception as error:
            messagebox.showerror('连接信息', safe_error(error), parent=self.root)
            return
        def completed(_):
            self.password.set('')
            self.connected = True
            self.update_buttons()
            self.status.set('已连接。正在加载激活码和用户…')
            self.refresh_all()
        def failed(error):
            if isinstance(error, UnknownHost):
                confirmed = messagebox.askyesno('核对服务器指纹',
                    '首次连接此服务器。请与 VPS 控制台的 SSH 主机指纹核对后再信任。\n\n'
                    + error.fingerprint + '\n\n是否信任并继续连接？', parent=self.root)
                if confirmed:
                    self.run('连接服务器', lambda: self.remote.connect(settings, approved=error), completed)
                    return
            self.password.set('')
            self.status.set('未连接。')
            messagebox.showerror('连接未完成', safe_error(error), parent=self.root)
        self.run('连接服务器', lambda: self.remote.connect(settings), completed, error=failed)

    def disconnect(self):
        self.remote.close()
        self.connected = False
        self.password.set('')
        self.query_code.set('')
        self.generated.clear()
        self.invites.clear()
        self.users.clear()
        self.invite_tree.delete(*self.invite_tree.get_children())
        self.user_tree.delete(*self.user_tree.get_children())
        self.status.set('已断开连接。本次生成的原码已从内存中清除。')
        self.update_buttons()

    def refresh_all(self):
        def operation():
            return self.remote.request('invites.list'), self.remote.request('users.list')
        def completed(result):
            self.render_invites(result[0])
            self.render_users(result[1])
            self.status.set('已连接。请选择激活码或用户进行管理。')
        self.run('加载列表', operation, completed)

    def render_invites(self, result, append=False):
        if not append:
            self.invites.clear()
            self.invite_tree.delete(*self.invite_tree.get_children())
        for value in result['items']:
            self.invites[value['id']] = value
            self.invite_tree.insert('', 'end', iid=value['id'], values=(value['id'], STATES.get(value['status'], '未知'),
                value['username'] or '—', display_time(value['createdAt']), display_time(value['expiresAt']),
                display_time(value['usedAt']) if value['usedAt'] else '—'))
        self.invite_next = result['next']

    def render_users(self, result, append=False):
        if not append:
            self.users.clear()
            self.user_tree.delete(*self.user_tree.get_children())
        for value in result['items']:
            self.users[value['id']] = value
            self.user_tree.insert('', 'end', iid=value['id'], values=(value['username'], '正常' if value['enabled'] else '已禁用',
                display_time(value['createdAt']), value['favorites'], value['history'], value['sessions'], value['revision']))
        self.user_next = result['next']

    def refresh_invites(self, append=False):
        if append and self.invite_next is None:
            self.status.set('激活码已全部加载。')
            return
        self.run('加载激活码', lambda: self.remote.request('invites.list', after=self.invite_next if append else 0),
                 lambda result: (self.render_invites(result, append), self.status.set('激活码列表已更新。')))

    def refresh_users(self, append=False):
        if append and self.user_next is None:
            self.status.set('用户已全部加载。')
            return
        self.run('加载用户', lambda: self.remote.request('users.list', after=self.user_next if append else 0),
                 lambda result: (self.render_users(result, append), self.status.set('用户列表已更新。')))

    def generate(self):
        try:
            count, days = int(self.count.get()), int(self.days.get())
            if not 1 <= count <= 100 or not 1 <= days <= 365:
                raise ValueError()
        except ValueError:
            messagebox.showerror('生成激活码', '数量为 1–100，有效天数为 1–365。', parent=self.root)
            return
        def completed(result):
            self.generated.extend(result['invites'])
            self.status.set(f'已生成并入库 {count} 个激活码。请在关闭程序前导出原码。')
            self.show_generated()
            self.refresh_invites()
        self.run('生成并入库', lambda: self.remote.request('invites.create', count=count, days=days), completed)

    def show_generated(self):
        if not self.generated:
            messagebox.showinfo('本次生成', '本次尚未生成激活码。服务器无法恢复以前生成的原码。', parent=self.root)
            return
        dialog = tk.Toplevel(self.root)
        dialog.title('本次生成的激活码')
        dialog.geometry('850x470')
        dialog.transient(self.root)
        frame = ttk.Frame(dialog, padding=18)
        frame.pack(fill='both', expand=True)
        ttk.Label(frame, text='原码仅在本次会话中显示，请妥善保管导出的文件。').pack(anchor='w', pady=(0, 10))
        codes = '\n'.join(f"{value['code']}    {value['id']}    {display_time(value['expiresAt'])}" for value in self.generated)
        content = ScrolledText(frame, font=('Consolas', 11), wrap='none', height=15)
        content.pack(fill='both', expand=True)
        content.insert('1.0', codes)
        content.configure(state='disabled')
        bar = ttk.Frame(frame)
        bar.pack(fill='x', pady=(12, 0))
        def copy():
            self.root.clipboard_clear()
            self.root.clipboard_append('\n'.join(value['code'] for value in self.generated))
            messagebox.showinfo('已复制', '本次生成的原码已复制到剪贴板。', parent=dialog)
        def export():
            path = filedialog.asksaveasfilename(title='保存本次激活码', parent=dialog,
                defaultextension='.csv', initialfile='聚阅激活码.csv', filetypes=[('CSV 文件', '*.csv')])
            if not path:
                return
            try:
                with open(path, 'w', encoding='utf-8-sig', newline='') as file:
                    writer = csv.writer(file)
                    writer.writerow(['管理编号', '激活码', '生成时间', '失效时间'])
                    writer.writerows([value['id'], value['code'], value['createdAt'], value['expiresAt']] for value in self.generated)
            except OSError:
                messagebox.showerror('导出失败', '文件无法保存，请检查目录权限。', parent=dialog)
                return
            messagebox.showinfo('已导出', '激活码已保存。请勿将此文件上传到公开仓库。', parent=dialog)
        ttk.Button(bar, text='复制原码', command=copy).pack(side='left')
        ttk.Button(bar, text='导出 CSV', command=export).pack(side='left', padx=8)
        ttk.Button(bar, text='关闭', command=dialog.destroy).pack(side='right')

    def check_code(self):
        code = self.query_code.get().strip()
        if not code:
            messagebox.showinfo('查询激活码', '请粘贴需要查询的原码。', parent=self.root)
            return
        def completed(result):
            self.query_code.set('')
            value = result['invite']
            message = ('未找到该激活码。' if value is None else
                f"状态：{STATES.get(value['status'], '未知')}\n管理编号：{value['id']}\n使用用户名：{value['username'] or '—'}\n"
                f"失效时间：{display_time(value['expiresAt'])}\n使用时间：{display_time(value['usedAt']) if value['usedAt'] else '—'}")
            self.status.set('原码查询完成。')
            messagebox.showinfo('查询结果', message, parent=self.root)
        self.run('查询激活码', lambda: self.remote.request('invites.check', code=code), completed)

    def selected(self, tree, values):
        selection = tree.selection()
        if not selection:
            messagebox.showinfo('请选择记录', '请先在列表中选择一条记录。', parent=self.root)
            return None
        return values.get(selection[0])

    def revoke_invite(self):
        value = self.selected(self.invite_tree, self.invites)
        if value is None:
            return
        if value['status'] != 'unused':
            messagebox.showinfo('撤销激活码', '只有尚未使用、未过期的激活码需要撤销。', parent=self.root)
            return
        if messagebox.askyesno('撤销激活码', f"撤销编号 {value['id']}？\n撤销后此原码无法用于注册。", parent=self.root):
            self.run('撤销激活码', lambda: self.remote.request('invites.revoke', id=value['id']), lambda _: self.refresh_invites())

    def toggle_user(self):
        value = self.selected(self.user_tree, self.users)
        if value is None:
            return
        verb = '禁用' if value['enabled'] else '启用'
        detail = '用户会退出全部设备，并且无法登录。书架和历史保留。' if value['enabled'] else '用户可以重新登录，书架和历史保留。'
        if messagebox.askyesno(verb + '用户', f"{verb}用户 {value['username']}？\n{detail}", parent=self.root):
            self.run(verb + '用户', lambda: self.remote.request('users.set_enabled', id=value['id'], enabled=not value['enabled']),
                     lambda _: self.refresh_users())

    def revoke_sessions(self):
        value = self.selected(self.user_tree, self.users)
        if value and messagebox.askyesno('退出全部设备', f"让用户 {value['username']} 退出全部设备？\n书架和历史保留，用户可以重新登录。", parent=self.root):
            self.run('退出全部设备', lambda: self.remote.request('users.revoke_sessions', id=value['id']), lambda _: self.refresh_users())

    def reset_password(self):
        value = self.selected(self.user_tree, self.users)
        if value is None:
            return
        dialog = tk.Toplevel(self.root)
        dialog.title('重置用户密码')
        dialog.transient(self.root)
        dialog.grab_set()
        frame = ttk.Frame(dialog, padding=20)
        frame.pack(fill='both', expand=True)
        ttk.Label(frame, text=f"用户：{value['username']}\n重置后全部设备退出登录，书架和历史保留。").pack(anchor='w')
        password, confirm = tk.StringVar(), tk.StringVar()
        for label, variable in [('新密码（8–128 字符）', password), ('再次输入', confirm)]:
            ttk.Label(frame, text=label).pack(anchor='w', pady=(10, 4))
            ttk.Entry(frame, textvariable=variable, width=42, show='●').pack(fill='x')
        def apply():
            secret = password.get()
            if not 8 <= len(secret.encode('utf-16-le')) // 2 <= 128 or not secret.strip():
                messagebox.showerror('重置密码', '密码长度为 8–128 字符。', parent=dialog)
                return
            if secret != confirm.get():
                messagebox.showerror('重置密码', '两次密码不一致。', parent=dialog)
                return
            if not messagebox.askyesno('确认重置', f"确认重置用户 {value['username']} 的密码并退出全部设备？", parent=dialog):
                return
            password.set('')
            confirm.set('')
            dialog.destroy()
            def completed(_):
                messagebox.showinfo('重置完成', '新密码已生效。', parent=self.root)
                self.refresh_users()
            self.run('重置密码', lambda: self.remote.request('users.reset_password', id=value['id'], password=secret), completed)
        ttk.Button(frame, text='确认重置', command=apply).pack(anchor='e', pady=(16, 0))

    def close(self):
        if self.busy and not messagebox.askyesno('退出管理程序', '操作仍在进行。直接退出后结果可能已在服务器生效，需要重新连接确认。\n是否退出？', parent=self.root):
            return
        if self.generated and not messagebox.askyesno('退出管理程序', '本次生成的激活码原码会从内存中清除。\n确认已经复制或导出，并退出？', parent=self.root):
            return
        self.closing = True
        self.remote.close()
        self.password.set('')
        self.generated.clear()
        self.root.destroy()


def main():
    root = tk.Tk()
    ManagerApp(root)
    root.mainloop()


if __name__ == '__main__':
    main()
