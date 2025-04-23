import { writeFileSync } from 'fs';

export function storeConstructorArgs(deployment: string, args: any[], timestamp: boolean = false) {
	const d: string[] = new Date().toLocaleString().split(', ');
	const id: string = `${d[0].replace(/\//g, '-')}_${d[1].replace(/:/g, '-').replace(/ /g, '_')}`;
	const dir: string = __dirname.split('/').slice(0, -1).join('/') + '/ignition/constructor-args/';
	const file: string = timestamp ? `${deployment}-${id}.js` : `${deployment}.js`;
	writeFileSync(
		dir + file,
		`module.exports = ${JSON.stringify(
			args.map((a) => {
				if (typeof a === 'bigint') return a.toString();
				else return a;
			})
		)};`
	);
}
