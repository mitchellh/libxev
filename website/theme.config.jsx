import { useRouter } from 'next/router'

export default {
  logo: <span>libxev</span>,
  docsRepositoryBase: 'https://github.com/mitchellh/libxev/blob/website/pages',

  project: {
    link: 'https://github.com/mitchellh/libxev',
  },

  feedback: {
    content: null,
  },

  footer: {
    text: <span>
      © {new Date().getFullYear()}
      <a href="https://github.com/mitchellh/libxev" target="_blank">libxev</a>
    </span>,
  },

  useNextSeoProps() {
    const { route } = useRouter()
    if (route !== '/') {
      return {
        titleTemplate: '%s – libxev'
      }
    }
  },

  // Hide the last updated date.
  gitTimestamp: <span></span>,
}
