const readline = require("node:readline/promises");
const colors = require('ansi-colors');
const fs = require('fs');
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
            console.log(gasReporter.printTableOldVsNew(table));
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
            console.log(gasReporter.printTableOldVsNew(table));
        }
    }
}

// ----------------------------

async function cmdGenerateReadme() {
    const README_MD = __dirname + '/../README.md';
    const START_MARKER = '## 📊 Benchmarks!';
    const END_MARKER = '## How does Tolk';

    const gasReporter = new GasReporter();
    const allContracts = gasReporter.getAllContracts();

    let strings = ['In gas units, plus code side (bits / cells).', '']
    for (let {numericFolder, shortTitle} of allContracts) {
        const allSavedRuns = gasReporter.parseAllBenchesForContract(numericFolder);
        const funcRun = allSavedRuns[0]
        const tolkLastRun = allSavedRuns[allSavedRuns.length - 1]
        const index = parseInt(numericFolder)

        let table = gasReporter.prepareTableOldVsNew(funcRun, tolkLastRun);
        strings.push(`### ${index < 10 ? '0' + index : index} — ${shortTitle}`);
        strings.push('');
        strings.push(`| Operation                       | FunC       | Tolk       | **Gas savings** |`);
        strings.push(`|---------------------------------|------------|------------|-----------------|`);

        for (const {column, cur, old, diff} of table) {
            let savings = column.startsWith('code size') ? '' : `**-${diff.toFixed(2)}%**`
            strings.push(`| ${column.padEnd(31)} | ${old.padEnd(10)} | ${cur.padEnd(10)} | ${savings.padEnd(15)} |`);
        }
        strings.push('');
    }
    strings.push('<br>')

    let readme = fs.readFileSync(README_MD, 'utf8');
    let pos1 = readme.indexOf(START_MARKER);
    let pos2 = readme.indexOf(END_MARKER);
    if (pos1 === -1 || pos2 === -1 || pos2 < pos1)
        throw 'Could not find positions in README.md';

    const newReadme = `${readme.slice(0, pos1 + START_MARKER.length)}\n\n${strings.join('\n')}\n\n${readme.slice(pos2)}`;
    fs.writeFileSync(README_MD, newReadme, 'utf8');
    console.log('README.md updated');
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
    case 'readme':
        cmdGenerateReadme().catch(console.error);
        break;
    default:
        console.error(`Unknown command ${argvCommand}`)
        process.exit(1)
}
