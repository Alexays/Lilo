declare module "virtual:lilo-release" {
	const release: import("./components/whatsnew/releaseNotes").ReleaseNotes;
	export default release;
}
