#!/usr/bin/env node

import {Argument, Command} from "commander";
import chalk from "chalk";
import {errorToString, safeParseInt} from "@azimutt/utils";
import {parseDatabaseUrl} from "@azimutt/database-types";
import {version} from "./version";
import {logger} from "./utils/logger";
import {exportDbSchema} from "./export";
import {availableConnectors, launchGateway} from "./gateway";

const clear = require('clear')
const figlet = require('figlet')
// https://github.com/SBoudrias/Inquirer.js

clear()
logger.log(chalk.hex('#4F46E5').bold(figlet.textSync('Azimutt.app', {horizontalLayout: 'full'})))
logger.log(chalk.hex('#3f3f46')(version))
logger.log('')

// TODO: `azimutt infer --path ~/my_db` or `azimutt export --url ~/my_db` (no 'protocol://') => recursively list .json files and infer them as a collection
// TODO: use in-memory H2 to load liquibase & flyway migrations
const program = new Command()
program.name('azimutt')
    .description('Export database schema from relational or document databases. Import it to https://azimutt.app.\n' +
        '- export database schemas from PostgreSQL, MongoDB and Couchbase')
    .version(version)

program.command('export')
    .description('Export a database schema in a file to easily import it in Azimutt.\nWorks with Couchbase, MariaDB, MongoDB, MySQL, PostgreSQL..., issues and PR are welcome in https://github.com/azimuttapp/azimutt ;)')
    .addArgument(new Argument('<kind>', 'the source kind of the export').choices(availableConnectors()))
    .argument('<url>', 'the url to connect to the source, including credentials')
    .option('-d, --database <database>', 'Limit to a specific database (ex for MongoDB)')
    .option('-s, --schema <schema>', 'Limit to a specific schema (ex for PostgreSQL)')
    .option('-b, --bucket <bucket>', 'Limit to a specific bucket (ex for Couchbase)')
    .option('-m, --mixed-collection <field>', 'When collection have mixed documents typed by a field')
    .option('--sample-size <number>', 'Number of items used to infer a schema', safeParseInt, 10)
    .option('--infer-relations', 'Infer relations using column names')
    .option('--ignore-errors', 'Do not stop export on errors, just log them')
    .option('-f, --format <format>', 'Output format', 'json')
    .option('-o, --output <output>', "Path to write the schema, ex: ~/azimutt.json")
    .option('--debug', 'Add debug logs and show the full stacktrace instead of a shorter error')
    .action((kind, url, args) => exec(exportDbSchema(kind, parseDatabaseUrl(url), args), args))

program.command('gateway')
    .description('Launch the gateway server to allow Azimutt to access your local databases.')
    .action(() => launchGateway(logger))

program.parse(process.argv)

if (!process.argv.slice(2).length) {
    program.outputHelp()
}

function exec(res: Promise<void>, args: any) {
    if (!args.debug) {
        res.catch(e => {
            logger.error(`Unexpected error: ${errorToString(e)}`)
            logger.log(`(use --debug option to see the full error)`)
        })
    }
}
