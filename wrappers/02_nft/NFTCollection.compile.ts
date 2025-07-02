import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['nft-collection.fc']
    lang: 'tolk',
    entrypoint: 'nft-collection-contract.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
