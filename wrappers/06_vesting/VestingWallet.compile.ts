import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['vesting_wallet.fc'],
    lang: 'tolk',
    entrypoint: 'VestingWallet.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
