Workflow for Authentication

  To authenticate with Claude or Gemini (browser-based subscription):

   1. Deploy the Auth Pod:
   1     helm install ralph-auth .helm --set job.name=ralph-auth
   2. Exec into the Pod:

   1     kubectl exec -it ralph-auth -- bash
   3. Run Login Command:
       * Claude: claude login (Follow the URL, paste the code).
       * Gemini: gemini login (or equivalent command for your CLI).
   4. Save Credentials to PVC:

   1     # For Claude
         rm -rf /work/.claude-auth
   2     cp -r ~/.claude /work/.claude-auth
   3     cp ~/.claude.json /work/  # If it exists
   4 
   5     # For Gemini
   6     cp -r ~/.gemini /work/.gemini
   5. Exit and Cleanup:
   1     exit
   2     kubectl delete pod ralph-auth



  # aiModel: "claude-sonnet-4-5-20250929"
  # aiModel: "claude-opus-4-5-20251101"