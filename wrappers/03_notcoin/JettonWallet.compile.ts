import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['jetton-wallet-not.fc'],
    lang: 'tolk',
    entrypoint: 'JettonWallet.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
