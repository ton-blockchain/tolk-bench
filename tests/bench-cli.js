const readline = require("node:readline/promises");
const colors = require('ansi-colors');
const GasReporter = require('./gas-reporter.js')

/** @return {Promise<string>} */
async function promptNumericFolder(/**string[]*/ allNumericFolders, allowAll = false) {
    let rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        completer: (/**string*/ line) => {
            const hits = allNumericFolders.filter(n => n.startsWith(line));
            return [hits.length ? hits : allNumericFolders, line];
        }
    });
    let numericFolder = await rl.question('contract: ');
    rl.close();

    if (allNumericFolders.includes(numericFolder)) {
        return numericFolder
    }
    if (allowAll && numericFolder === 'all') {
        return 'all'
    }
    throw "invalid contract name"
}

/** @return {Promise<string>} */
async function promptCommitDesc() {
    let rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });
    let commitDesc = await rl.question('commit message: ');
    rl.close();

    commitDesc = commitDesc.trim();
    if (commitDesc !== '') {
        return commitDesc
    }
    throw "empty description"
}

// ----------------------------

async function cmdSave() {
    const gasReporter = new GasReporter();
    const allContracts = gasReporter.getAllContracts();

    const withLastRun = allContracts.filter(c => gasReporter.parseLastRunForContract(c.numericFolder)).map(c => c.numericFolder)
    if (!withLastRun.length) {
        throw "no contracts having last run"
    }

    let numericFolder = ''
    if (withLastRun.length === 1) {
        numericFolder = withLastRun[0]
        console.log(`contract: ${numericFolder}`)
    } else {
        console.log(`choose: ${withLastRun.join(', ')}, all`)
        numericFolder = await promptNumericFolder(allContracts.map(c => c.numericFolder), true);
    }

    let commitDesc = await promptCommitDesc();

    if (numericFolder !== 'all') {
        gasReporter.persistLastRunIntoBenchFile(numericFolder, commitDesc);
        console.log(`Done: saved ${numericFolder}`)
    } else {
        allContracts.forEach(c => {
            gasReporter.persistLastRunIntoBenchFile(c.numericFolder, commitDesc);
        })
        console.log(`Done: saved all ${allContracts.length}`)
    }
}

// ----------------------------

async function cmdShow() {
    const gasReporter = new GasReporter();
    const allContracts = gasReporter.getAllContracts();

    console.log('choose a contract (show detailed table) or "all" (show compared to FunC)')
    let numericFolder = await promptNumericFolder(allContracts.map(c => c.numericFolder), true);

    if (numericFolder !== 'all') {
        const allSavedRuns = gasReporter.parseAllBenchesForContract(numericFolder);
        for (let i = 1; i < allSavedRuns.length; ++i) {
            let prevRun = allSavedRuns[i - 1]
            let curRun = allSavedRuns[i]

            let table = gasReporter.prepareTableOldVsNew(prevRun, curRun);
            console.log(`\n •  ${colors.bold(curRun.commitDesc)}\n`);
            console.log(table.join('\n'));
        }
    } else {
        for (let {numericFolder} of allContracts) {
            const allSavedRuns = gasReporter.parseAllBenchesForContract(numericFolder);
            if (allSavedRuns.length < 2) {
                console.log(`\n${numericFolder} skip, has ${allSavedRuns.length} run`)
                continue
            }
            let funcRun = allSavedRuns[0]
            let tolkLastRun = allSavedRuns[allSavedRuns.length - 1]

            let table = gasReporter.prepareTableOldVsNew(funcRun, tolkLastRun);
            console.log(`\n •  ${colors.bold(numericFolder)}`);
            console.log(`    FunC vs Tolk\n`);
            console.log(table.join('\n'));
        }
    }
}

// ----------------------------

const argvCommand = process.argv[2];
switch (argvCommand) {
    case 'save':
    case 'commit':
        cmdSave().catch(console.error);
        break;
    case 'show':
        cmdShow().catch(console.error);
        break;
    default:
        console.error(`Unknown command ${argvCommand}`)
        process.exit(1)
}
