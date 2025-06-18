import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['jetton-wallet.fc'],
    lang: 'tolk',
    entrypoint: 'jetton-wallet.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
