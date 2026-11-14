import 'commands.dart';

/// A page of the help (3.0 spec 002): an introduction and the commands of its section from the registry.
class HelpTopic {
  const HelpTopic(this.id, this.title, this.body, {this.section});

  final String id;
  final String title;

  /// Paragraphs separated by empty lines; lines starting with `    ` are code.
  final String body;

  /// The commands of this section are listed under the body.
  final CommandSection? section;

  List<AppCommand> get commands => section == null ? const [] : appCommands.where((c) => c.section == section).toList();
}

/// What a problem code means and how to fix it.
class ProblemHelp {
  const ProblemHelp(this.code, this.title, this.body, {this.before, this.after});

  final String code;
  final String title;
  final String body;
  final String? before;
  final String? after;
}

const helpTopics = <HelpTopic>[
  HelpTopic(
    'start',
    'PG Studio',
    'PG Studio reads a folder of PostgreSQL database files - tables, views, functions, procedures, Liquibase '
        'changesets - and understands them without a database connection: where each object is defined, who uses it, '
        'what a change breaks.\n\n'
        'Open a folder (Ctrl+O). Every .sql file is parsed by the parser of PostgreSQL itself (libpg_query 18) in '
        'the background; the status bar shows the number of files, objects, references and problems. The last folder '
        'opens again at the next start, with its tabs and cursors.\n\n'
        'Right-click anything - a name in the editor, a tab, a file or object in the tree, a row of a panel - to see '
        'what can be done with it. Every command has its shortcut next to it.',
  ),
  HelpTopic(
    'files',
    'Files and tabs',
    'The Files tree shows the folder as on disk, Objects shows objects by schema, Modules by module (in folders '
        'with changelog/modules/<nn>-<module>/). A number next to a file is its count of problems.\n\n'
        'A tab keeps unsaved text, and the index follows it: references, problems and hover use what you typed, '
        'not what is on disk. Files changed outside (git checkout, an agent, the terminal) reload in tabs without '
        'unsaved changes; a tab with unsaved changes asks whether to reload or keep your edits.',
    section: CommandSection.files,
  ),
  HelpTopic(
    'navigation',
    'Navigation',
    'Ctrl+click a name (or F12) to open its definition; a routine with overloads opens the one matching the '
        'number of arguments. Hover a name to see its signature, columns, the changeset comment and where it is '
        'defined.\n\n'
        'Every jump is remembered: Alt+Left and Alt+Right go back and forward, like in a browser.',
    section: CommandSection.navigation,
  ),
  HelpTopic(
    'writing',
    'Writing',
    'While you type, the editor offers objects, columns of the tables in the statement (by alias: o. lists the '
        'columns of the table aliased o), and parameters. Inside CALL x( or a function call, the signature shows '
        'with the current parameter.\n\n'
        'A syntax error is underlined while you type, about a third of a second after the last key. Format '
        'changes whitespace only and never touches changesets already deployed (no runOnChange, present in main), '
        'because Liquibase would reject their new checksum.',
    section: CommandSection.writing,
  ),
  HelpTopic(
    'refactoring',
    'Changes and refactoring',
    'Before changing an object or a column, Impact (Shift+Alt+F12) lists what uses it - directly and through '
        'views - with how (read, write, call).\n\n'
        'Rename (F2) changes every place in the project and shows the change as a diff first, with warnings: a view '
        'whose output column changes its name changes the API contract; deployed changesets are never edited. For '
        'a column or a table it also writes a dated changeset with ALTER ... RENAME and a CHANGELOG.md line.',
    section: CommandSection.refactoring,
  ),
  HelpTopic(
    'review',
    'Review and history',
    'History lists every changeset that created or changed an object, in Liquibase order, with its date and '
        'comment; for a table also the effective DDL after all of them.\n\n'
        'Changes (the Changes panel) compares the current git branch with main: objects added and changed, '
        'problems that are new on the branch, and deployed changesets that were edited - review an agent\'s work '
        'here before merging.',
    section: CommandSection.review,
  ),
  HelpTopic(
    'view',
    'Panels and view',
    'The bottom panel has Problems, References, Search, History, Changes, Graph (object, module and ER '
        'diagram; the ER diagram resets its zoom and opens in its own window), Error codes (every ERRCODE with its comment) and Contract (the <module>_app objects of each '
        'module). Right-click a row to copy it or its file:line:column.',
    section: CommandSection.view,
  ),
  HelpTopic(
    'terminal',
    'Terminal',
    'Ctrl+` opens a terminal in the bottom panel: your shell (\$SHELL) in the project folder, with the whole '
        'environment of the app, so git, liquibase, pg-studio check and claude work as in any terminal. Several '
        'terminals live in tabs named after the program in the foreground.\n\n'
        'Files written from the terminal (git checkout, an agent, a script) are picked up at once: the index '
        'follows, and tabs without unsaved changes reload. Ctrl+click a path such as changelog/x.sql:12:5 in the '
        'output to open it there.\n\n'
        'Closing a terminal ends its shell and everything started from it. Closing PG Studio while a program runs '
        'in a terminal asks first. PG Studio itself still never connects to a database - what you run in your '
        'shell is up to you.',
    section: CommandSection.terminal,
  ),
  HelpTopic(
    'modules',
    'Module conventions',
    'In folders with changelog/modules/<nn>-<module>/ PG Studio checks the conventions of the stack, the same '
        'rules as db/scripts/check-module-changesets.sh (when the script exists, or with '
        '{"conventions": {"rules": true}} in .pgstudio.json):\n\n'
        '- a module uses only modules with a lower number;\n'
        '- other modules are used through their <module>_app contract (views, functions, procedures), never their '
        'tables or _internal routines; foreign keys and platform functions are allowed;\n'
        '- file names, changeset ids, SET LOCAL ROLE <owner> and RESET ROLE, jsonb and timestamptz, a CHANGELOG.md '
        'line for every dated changeset;\n'
        '- ERRCODE U1xxx codes with a comment such as -- U1445 (404): ..., one HTTP status per code.\n\n'
        'Ctrl+N creates a procedure, function, view or dated changeset that already follows them.',
  ),
  HelpTopic(
    'cli',
    'Command line and Claude Code',
    'The same index works without the window:\n\n'
        '    pg-studio check db/                 problems as file:line:column, exit 1 on errors\n'
        '    pg-studio refs db/ orders.purchase_orders --kind write\n'
        '    pg-studio format db/ --check        files the formatter would change\n'
        '    claude mcp add pg-studio -- pg-studio-cli mcp /path/to/app/db\n\n'
        'The MCP server gives an agent the tools problems, definition, references, graph, modules, contract, '
        'error_codes and format_check, so it reads the index instead of grepping.',
  ),
  HelpTopic(
    'help',
    'Help',
    'F1 opens this help; on a line with a problem it opens the description of that problem. Search finds '
        'commands, shortcuts and topics.',
    section: CommandSection.help,
  ),
];

const problemHelp = <ProblemHelp>[
  ProblemHelp(
    'syntax',
    'Syntax error',
    'The parser of PostgreSQL (libpg_query 18) rejects the statement. The underline starts at the token where '
        'the parser stopped - the mistake is there or just before it. Each changeset is parsed alone, so the rest '
        'of the file is still analysed.',
    before: 'SELECT count(*) FROM FROM sales.orders',
    after: 'SELECT count(*) FROM sales.orders',
  ),
  ProblemHelp(
    'plpgsql',
    'PL/pgSQL error',
    'The body of a LANGUAGE plpgsql function or procedure does not compile: a missing END IF or END LOOP, a '
        'wrong RAISE, a statement that is not allowed there. The position is the line PostgreSQL reports.',
    before: 'IF NOT FOUND THEN\n    RAISE EXCEPTION \'No order\';\nEND;',
    after: 'IF NOT FOUND THEN\n    RAISE EXCEPTION \'No order\';\nEND IF;',
  ),
  ProblemHelp(
    'unresolved',
    'Not defined in the project',
    'A schema-qualified name in a clear place (FROM, JOIN, INSERT INTO, CALL, %ROWTYPE, a type) is not created '
        'by any file of the folder. Usually a typo, a changeset that is missing, or an object created outside the '
        'folder. Unqualified names, built-ins (pg_catalog), aliases, CTEs and names in dynamic SQL are never '
        'reported.',
    before: 'CALL sales_app.order_sav(p_id);',
    after: 'CALL sales_app.order_save(p_id);',
  ),
  ProblemHelp(
    'module-order',
    'Module uses a higher module',
    'Modules are deployed in number order, so a module may use only modules with a lower number. Move the code '
        'to the higher module, or turn the dependency around (the lower module offers a contract the higher one '
        'calls).',
    before: '-- in 50-inventory\nSELECT ... FROM orders_app.purchase_orders',
    after: '-- the query belongs to 60-orders (or later), which may read inventory_app',
  ),
  ProblemHelp(
    'module-boundary',
    'Module reads another module\'s tables',
    'Other modules are used through their <module>_app contract: views, functions and procedures with a stable '
        'shape. Their tables and _internal routines can change at any time. Foreign keys to their tables and the '
        'platform functions are allowed.',
    before: 'SELECT o.status FROM orders.purchase_orders AS o',
    after: 'SELECT o.status FROM orders_app.purchase_orders AS o',
  ),
  ProblemHelp(
    'module-rule',
    'Rule of check-module-changesets.sh',
    'A rule of db/scripts/check-module-changesets.sh, with the same message as the script: file names, changeset '
        'ids, SET LOCAL ROLE <owner> at the start and RESET ROLE at the end, jsonb instead of json, timestamptz '
        'instead of timestamp, a CHANGELOG.md line for a dated changeset. Some have a quick fix: Ctrl+. or the '
        'Fix button in Problems.',
    before: 'note json',
    after: 'note jsonb',
  ),
  ProblemHelp(
    'errcode-status',
    'ERRCODE with different HTTP statuses',
    'The same ERRCODE is described with different HTTP statuses in its comments (-- U1101 (404) here, '
        '-- U1101 (409) there). The API maps one code to one status: use another code for the other case, or fix '
        'the comment.',
    before: '-- U1101 (409): the customer is blocked.',
    after: '-- U1102 (409): the customer is blocked.',
  ),
  ProblemHelp(
    'internal',
    'Internal analysis error',
    'The analysis of this file failed - a bug in PG Studio, not in your SQL. The rest of the folder is analysed '
        'normally. Please report it with the file.',
  ),
  ProblemHelp('io', 'File cannot be read', 'The file could not be read: permissions, a broken link, or not UTF-8.'),
];

ProblemHelp? problemHelpOf(String? code) => problemHelp.where((h) => h.code == code).firstOrNull;
